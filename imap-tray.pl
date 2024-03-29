#!/usr/bin/perl
# ------------------------------------------------------------------------------
use utf8::all;
use open qw/:std :utf8/;
use Modern::Perl;

# ------------------------------------------------------------------------------
use lib q{.};
use Array::OrdHash;
use Carp qw/confess carp cluck/;
use Config::Find;
use Const::Fast;
use Domain::PublicSuffix;
use Encode qw/decode_utf8/;
use Encode::IMAPUTF7;
use English qw/-no_match_vars/;
use Fcntl qw/:flock/;
use File::Basename;
use File::Temp qw/tempfile/;
use Gtk3 qw/-init/;
use LWP::Simple;
use Mail::IMAPClient;
use Mutex;
use Sys::Syslog;
use Try::Tiny;
use URI;

# ------------------------------------------------------------------------------
our $VERSION = 'v2.2';

# ------------------------------------------------------------------------------
my ( undef, $APP_DIR ) = fileparse($PROGRAM_NAME);

const my $APP_NAME      => 'IMAP-Tray';
const my $GET_FAVICON   => 'http://www.google.com/s2/favicons?domain=%s';
const my $ICO_INACTIVE  => 0.01;
const my $ICO_ERROR     => 10;
const my $BUTTON_LEFT   => 1;
const my $BUTTON_RIGHT  => 3;
const my $INT_MAX       => ~0;
const my $SEC_IN_MIN    => 60;
const my $APP_ICO_PATH  => $APP_DIR . 'i/';
const my $IMAP_ICO_PATH => $APP_DIR . 'i/m/';
const my %APP_ICO_SRC   => (
    normal    => 'normal.png',
    error     => 'error.png',
    reconnect => 'reconnect.png',
    reload    => 'reload.png',
    getmail   => 'getmail.png',
    quit      => 'quit.png',
    imap      => 'imap.png',
    digits    => 'digits.png',
);
const my $PDS       => Domain::PublicSuffix->new;
const my $MUTEX => Mutex->new;

my ( $TRAYICON, $OPT, %APP_ICO );
_app_init();
local $SIG{ALRM} = \&_mail_loop;
local $SIG{HUP}  = \&_app_reload;
alarm 1;

Gtk3->main;

# ------------------------------------------------------------------------------
sub _app_reload
{
    $MUTEX->lock;
    _disconnect_all();
    _app_init();
    alarm 1;
    $MUTEX->unlock;
}

# ------------------------------------------------------------------------------
sub _app_init
{
    undef $OPT;
    undef $TRAYICON;
    undef %APP_ICO;

    $OPT = _get_config();
    _init_app_ico();

    # Convert IMAP hash to ordered hash.
    # Use Array::OrdHash, not Hash::Ordered, because
    # 'each' and '->{}' syntax is identical to native hashes.
    my $oh = Array::OrdHash->new;
    $oh->{$_} = $OPT->{imap}->{$_} for sort keys %{ $OPT->{imap} };
    $OPT->{imap} = $oh;

    while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
        _init_imap_data($data);
    }
    $TRAYICON = _create_tray_icon();
}

# ------------------------------------------------------------------------------
sub _mail_loop
{
    $MUTEX->lock;

    my ( $errors, $unseen, @tooltip ) = ( 0, 0 );

    while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
        next unless $data->{mail_active};
        my ( $now, $error ) = (time);

        if ( $data->{mail_next} <= $now ) {
            undef $data->{mail_error};
            $error = _check_one_imap( $name, $data ) unless $error;
            $data->{mail_next} = time + $data->{interval} * $SEC_IN_MIN;
        }
        else {
            $error = $data->{mail_error};
        }

        if ($error) {
            push @tooltip, $name . ' :: ' . $error;
            $data->{mail_error} = $error;
            ++$errors;
        }

        if ( $data->{detailed} ) {
            for my $i ( 0 .. $#{ $data->{mailboxes} } ) {
                my $sunseen = $data->{mail_boxes}->[$i]->[1];
                if ($sunseen) {
                    $sunseen .= '(?)' if $error;
                    push @tooltip, $name . q{[} . $data->{mailboxes}->[$i] . '] :: ' . $sunseen . ' new';
                }
            }
        }
        else {
            my $sunseen = $data->{mail_unseen};
            if ($sunseen) {
                $sunseen .= '(?)' if $error;
                push @tooltip, $name . ' :: ' . $sunseen . ' new';
            }
        }
        $unseen += $data->{mail_unseen};
    }

    my $ico = 'normal';
    if ($errors) {
        $ico = 'error';
    }

    my $pixbuf = _set_unseen( $unseen, $ico );

    $TRAYICON->set_from_pixbuf($pixbuf);
    $TRAYICON->set_tooltip_text( join "\n", @tooltip );

    alarm $SEC_IN_MIN;

    $MUTEX->unlock;
    return;
}

# ------------------------------------------------------------------------------
sub _set_unseen
{
    my ( $unseen, $ico ) = @_;

    my $pixbuf = $APP_ICO{$ico}->get_pixbuf->copy;
    return $pixbuf unless $unseen;

    my $x      = 12 - 3;
    my $number = $unseen;
    $number = 999 if $number > 999;

    if ( $number < 100 && $number > 9 ) {
        $x = 12;
    }
    elsif ( $number > 99 ) {
        $x = 24 - 7 - 2;
    }

    while ($number) {
        my $digit = $number % 10;
        $APP_ICO{digits}->get_pixbuf->copy_area( $digit * 7, 0, 7, 9, $pixbuf, $x, 8 );
        $number = int( $number / 10 );
        $x -= 7;
    }

    return $pixbuf;
}

# ------------------------------------------------------------------------------
sub _check_one_imap
{
    my ( $name, $data ) = @_;

    return unless $data->{mail_active};

    $data->{mail_unseen} = 0;
    ++$data->{mail_count};
    if ( $data->{reconnectafter} == $INT_MAX ) {
        _dbg( '%s :: checking mail, attempt %u...', $name, $data->{mail_count} );
    }
    else {
        _dbg( '%s :: checking mail, attempt %u from %u...', $name, $data->{mail_count}, $data->{reconnectafter} );
    }

    my $error;
    $error = _imap_login( $name, $data ) unless $data->{imap}->IsAuthenticated;

    unless ($error) {
        for my $i ( 0 .. $#{ $data->{mailboxes} } ) {
            my $unseen = $data->{imap}->unseen_count( $data->{mail_boxes}->[$i]->[0] ) // 0;
            $error = sprintf 'invalid "unsees" value (%s)', $unseen if $unseen !~ /^\d+$/gsm;
            $error = $data->{imap}->LastError unless $error;
            last if $error;
            $data->{mail_unseen} += $unseen;
            $data->{mail_boxes}->[$i]->[1] = $unseen;
            _dbg( '%s[%s] :: OK, unseen: %u', $name, $data->{mailboxes}->[$i], $unseen );
        }
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gsm;
        _dbg( '%s :: error %s', $name, $error );
    }
    else {

        if ( $data->{mail_count} >= $data->{reconnectafter} ) {
            _dbg( '%s :: max attempts (%u), logout', $name, $data->{mail_count} );
            $data->{imap}->logout;
        }

    }
    return $error;
}

# ------------------------------------------------------------------------------
sub _imap_login
{
    my ( $name, $data ) = @_;

    my $error;
    $error = sprintf 'Can not login to "%s" :: %s', $name,
        $EVAL_ERROR
        unless $data->{imap}->connect(
        User     => $data->{user},
        Password => $data->{password},
        );

    _dbg( '%s', $error ) if $error;

    return $error;
}

# ------------------------------------------------------------------------------
sub _create_tray_icon
{
    my $ti = Gtk3::StatusIcon->new;
    $ti->set_from_pixbuf( $APP_ICO{normal}->get_pixbuf );

    $ti->signal_connect(

        button_press_event => sub {
            my ( undef, $event ) = @_;
            if ( $event->button == $BUTTON_RIGHT ) {
                my ( $menu, $item ) = ( Gtk3::Menu->new );
                while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
                    $name .= sprintf ' (%u)', $data->{mail_unseen} if $data->{mail_unseen};
                    $item = Gtk3::ImageMenuItem->new($name);
                    my $dest = $data->{image}->get_pixbuf->copy;
                    if ( !$data->{mail_active} ) {
                        $dest->saturate_and_pixelate( $dest, $ICO_INACTIVE, 1 );
                    }
                    elsif ( $data->{mail_error} ) {
                        $dest->saturate_and_pixelate( $dest, $ICO_ERROR, 1 );
                    }
                    my $image = Gtk3::Image->new_from_pixbuf($dest);
                    $item->set_image($image);
                    $item->signal_connect(
                        activate => sub {
                            $data->{mail_active} ^= 1;
                            if ( !$data->{active} ) {
                                $data->{imap}->logout unless $data->{imap}->IsAuthenticated;
                            }
                        }
                    );
                    $item->show;
                    $menu->append($item);
                }

                $item = Gtk3::SeparatorMenuItem->new;
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Get all mail now');
                $item->set_image( $APP_ICO{getmail} );
                $item->signal_connect(
                    activate => sub {
                        _dbg( '%s', 'Get all mail request received.' );
                        while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
                            $data->{mail_next} = time if $data->{mail_active};
                        }
                        alarm 1;
                    }
                );
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Reconnect all');
                $item->set_image( $APP_ICO{reconnect} );
                $item->signal_connect(
                    activate => sub {
                        _dbg( '%s', 'Reconnect all request received.' );
                        $MUTEX->lock;
                        _disconnect_all();
                        alarm 1;
                        $MUTEX->unlock;
                    }
                );
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Full reload');
                $item->set_image( $APP_ICO{reload} );
                $item->signal_connect(
                    activate => sub {
                        _dbg( '%s', 'Full reload request received.' );
                        _app_reload();
                    }
                );
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Quit');
                $item->set_image( $APP_ICO{quit} );
                $item->signal_connect( activate => sub { Gtk3->main_quit } );
                $item->show;
                $menu->append($item);

                $menu->show_all;
                $menu->popup( undef, undef, undef, undef, $event->button, $event->time );
            }
            elsif ( $event->button == $BUTTON_LEFT ) {
                _on_click();
            }
            1;
        }

    );
    return $ti;
}

# ------------------------------------------------------------------------------
sub _on_click
{
    if ( ref $OPT->{onclick} eq 'CODE' ) {
        return &{ $OPT->{onclick} };
    }
    my $cmd = $OPT->{onclick};
    $cmd =~ s/^\s+|\s+$//gsm;
    _dbg( 'Executing "%s"...', $cmd );
    return system $OPT->{onclick};
}

# ------------------------------------------------------------------------------
sub _icon_from_file
{
    my ($file) = @_;
    my $ico;
    try {
        my $pb = Gtk3::Gdk::Pixbuf->new_from_file($file);
        $ico = Gtk3::Image->new_from_pixbuf($pb);
    }
    catch {
        return _confess( "Can not create icon from file \"%s\":\n %s", $file, $ERRNO );
    };
    return $ico;
}

# ------------------------------------------------------------------------------
sub _reset_imap_data
{
    my ($data) = @_;

    $data->{interval}    = $OPT->{interval} unless $data->{interval};
    $data->{mail_next}   = time;
    $data->{mail_unseen} = 0;
    $data->{mail_total}  = 0;
    $data->{mail_active} = $data->{active} // 0;
    $data->{reconnectafter} //= $INT_MAX;
    undef $data->{mail_error};
    return $data;
}

# ------------------------------------------------------------------------------
sub _init_imap_data
{
    my ($data) = @_;

    _reset_imap_data($data);

    push @{ $data->{mail_boxes} }, [ Encode::IMAPUTF7::encode( 'IMAP-UTF-7', $_ ), 0 ] for @{ $data->{mailboxes} };

    my $ico  = $data->{icon};
    my $uri  = URI->new( 'http://' . $data->{host} );
    my $root = $PDS->get_root_domain( $uri->host );
    if ( !$ico ) {
        if ( $root && -e $IMAP_ICO_PATH . $root . '.png' ) {
            $ico = $IMAP_ICO_PATH . $root . '.png';
        }
        else {
            $data->{image} = $APP_ICO{imap};
            undef $ico;
        }
    }
    elsif ( $ico eq 'online' ) {
        my $icon = get( sprintf $GET_FAVICON, $uri->host );
        $icon = get( sprintf $GET_FAVICON, $root ) unless $icon;
        if ($icon) {
            my ( $fh, $filename ) = tempfile( UNLINK => 1 );
            if ($fh) {
                binmode $fh, ':bytes';
                print {$fh} $icon;
                close $fh;
                $ico = $filename;
            }
            else {
                $data->{image} = $APP_ICO{imap};
                undef $ico;
            }
        }
        else {
            $data->{image} = $APP_ICO{imap};
            undef $ico;
        }
    }
    else {
        $ico = $IMAP_ICO_PATH . $ico;
    }
    $data->{image} = _icon_from_file($ico) if $ico;

    undef $data->{imap};
    $data->{imap} = Mail::IMAPClient->new(
        Server => $data->{host},
        %{ $data->{opt} },
    );

    return;
}

# ------------------------------------------------------------------------------
sub _init_app_ico
{
    while ( my ( $k, $v ) = each %APP_ICO_SRC ) {
        $APP_ICO{$k}
            = _icon_from_file( $APP_ICO_PATH . ( defined $OPT->{icons}->{$k} ? $OPT->{icons}->{$k} : $v ) );
    }
    return;
}

# ------------------------------------------------------------------------------
sub _get_config
{
    my $config = $ARGV[0] ? $ARGV[0] : Config::Find->find;
    return _confess( '%s', 'Can not detect config file location' ) unless $config;

    my $cfg = do $config;
    _confess( 'Invalid config file "%s": %s', $config, $EVAL_ERROR ? $EVAL_ERROR : $ERRNO ) unless $cfg;
    $cfg = _convert( $cfg, q{_} );

    my $cerr = _check_config($cfg);
    return _confess( '%s', $cerr ) if $cerr;
    return $cfg;
}

# ------------------------------------------------------------------------------
sub _lc_key
{
    my ( $key, $top ) = @_;
    return $top eq 'IMAP' ? $key : lc $key;
}

# ------------------------------------------------------------------------------
sub _convert
{
    my ( $src, $top ) = @_;

    my $dest;
    if ( ref $src eq 'ARRAY' ) {
        @{$dest} = map { _convert( $_, $_ ) } @{$src};
    }
    elsif ( ref $src eq 'HASH' ) {
        %{$dest} = map { _lc_key( $_, $top ) => _convert( $src->{$_}, $_ ); }
            keys %{$src};
    }
    else {
        $dest = decode_utf8 $src;
    }
    return $dest;
}

# ------------------------------------------------------------------------------
sub _cfg_val_empty
{
    my ( $cfg, $key ) = @_;
    $cfg->{$key} && $cfg->{$key} =~ s/^\s+|\s+$//gsm;
    return $cfg->{$key};
}

# ------------------------------------------------------------------------------
sub _check_config
{
    my ($cfg) = @_;

    return 'No "OnClick" action' unless _cfg_val_empty( $cfg, 'onclick' );
    return 'Bad "Interval" key'
        if !$cfg->{interval}
        || $cfg->{interval} !~ /^\d+$/sm;

    return 'Invalid "IMAP" list' unless ref $cfg->{imap} eq 'HASH';

    while ( my ( $name, $data ) = each %{ $cfg->{imap} } ) {

        return "No \"host\" key in \"IMAP/$name\""     unless _cfg_val_empty( $data, 'host' );
        return "No \"password\" key in \"IMAP/$name\"" unless _cfg_val_empty( $data, 'password' );
        return "No \"user\" key in \"IMAP/$name\""     unless _cfg_val_empty( $data, 'user' );

        return "No mailboxes in \"IMAP/$name\""
            if ref $data->{mailboxes} ne 'ARRAY'
            || $#{ $data->{mailboxes} } < 0;
        @{ $data->{mailboxes} } = sort @{ $data->{mailboxes} };
        return "Invalid \"ReconnectAfter\" value in \"IMAP/$name\""
            if $data->{reconnectafter} && $data->{reconnectafter} !~ /^\d+$/sm;
        undef $data->{opt}->{user};
        undef $data->{opt}->{password};
    }
    return;
}

# ------------------------------------------------------------------------------
sub _now
{
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime time;
    return sprintf '[%04u-%02u-%02u %02u:%02u:%02u]', $year + 1900, $mon + 1, $mday, $hour, $min, $sec;
}

# ------------------------------------------------------------------------------
sub _dbg
{
    my ( $fmt, @data ) = @_;
    if ( $OPT->{debug} ) {
        my $s = sprintf "(%u) %s %s\n", $PID, _now(), sprintf $fmt, @data;
        if ( $OPT->{debug} eq 'warn' ) {
            warn $s;

        }
        elsif ( $OPT->{debug} eq 'carp' ) {
            carp $s;

        }
        elsif ( $OPT->{debug} =~ m/^file:(.+)/sm ) {
            my ( $dfile, $out ) = ($1);
            if ( open( $out, '>>', $dfile ) && flock $out, LOCK_EX ) {
                print {$out} $s;
                CORE::close($out);
            }
            else {
                cluck sprintf '%s Debug IO to "%s" failed (%s), switch to "warn"...', _now(), $dfile, $ERRNO;
                $OPT->{debug} = 'warn';
                _dbg( $fmt, @data );
            }

        }
        elsif ( $OPT->{debug} eq 'syslog' ) {
            _syslog( 'debug', $s );
        }
        else {
            print {*STDOUT} $s;
        }
    }
    return;
}

# ------------------------------------------------------------------------------
sub _syslog
{
    my ( $prio, $msg ) = @_;
    openlog( "[$APP_NAME $VERSION]", 'ndelay,nofatal', 'user' );
    syslog( $prio, '%s', $msg );
    closelog();
}

# ------------------------------------------------------------------------------
sub _confess
{
    my ( $fmt, @data ) = @_;
    my $msg = sprintf $fmt, @data;
    _syslog( 'err', $msg );
    confess $msg;
}

# ------------------------------------------------------------------------------
sub _disconnect_all()
{
    if ($OPT) {
        while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
            _dbg( 'Disconnecting "%s"...', $name );
            $data->{imap}->logout if $data->{imap} && !$data->{imap}->IsAuthenticated;
            _reset_imap_data($data);
        }
    }
}

# ------------------------------------------------------------------------------
END {
    _disconnect_all();
}

# ------------------------------------------------------------------------------
__END__

=pod

=head1 NAME

IMAP-Tray

=head1 DEPENDENCIES 

=over

=item L<utf8::all>

=item L<Modern::Perl>

=item L<Array::OrdHash>

=item L<Carp>

=item L<Config::Find>

=item L<Const::Fast>

=item L<Domain::PublicSuffix>

=item L<Encode::IMAPUTF7>

=item L<Encode>

=item L<English>

=item L<Fcntl>

=item L<File::Basename>

=item L<File::Temp>

=item L<Gtk3>

=item L<LWP::Simple>

=item L<Mail::IMAPClient>

=item L<Mutex>

=item L<Sys::Syslog>

=item L<Try::Tiny>

=item L<URI>

=back

=head1 SYNOPSIS

./imap-tray.pl [config_file]

=head1 USAGE

./imap-tray.pl [config_file]

=head1 LICENSE AND COPYRIGHT

Coyright (C) 2016 Vsevolod Lutovinov.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. The full text of this license can be found in
the LICENSE file included with this module.

=head1 AUTHOR

Contact the author at klopp@yandex.ru.

=head1 SOURCE CODE

Source code and issues can be found L<here|https://github.com/klopp/imap-tray>

=head1 BUGS AND LIMITATIONS

=head2 L<birdtray|https://github.com/gyunaev/birdtray>

    OnClick => 'birdtray -s'

=head1 CONFIGURATION

See C<imap-tray.conf.sample>

=head1 DIAGNOSTICS

=head2 Application debug

    Debug => 'warn', # use warn

or

    Debug => 'carp', # use carp

or

    Debug => 'file:/var/log/imap-tray.log', # use file, switch to warn if file open error

Use STDOUT in other cases (if not undef/0 etc).

=head2 Mail server debug

Some as "Application debug", but use C<IMAP/Server> secton:

    IMAP => 
    {
        Yandex => {
            Opt =>
            {
                Debug => ...            
            },
        },
    }

=head2 Fatal errors

Use C<syslog (ndelay,nofatal', 'user')>.

=cut

