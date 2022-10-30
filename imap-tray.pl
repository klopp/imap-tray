#!/usr/bin/perl
# ------------------------------------------------------------------------------
use utf8::all;
use open qw/:std :utf8/;
use Modern::Perl;

# ------------------------------------------------------------------------------
use lib q{.};
use Array::OrdHash;
use Carp qw/confess/;
use Config::Find;
use Const::Fast;
use Domain::PublicSuffix;
use Encode::IMAPUTF7;
use English qw/-no_match_vars/;
use File::Basename;
use File::Temp qw/tempfile/;
use Gtk3 qw/-init/;
use LWP::Simple;
use Net::IMAP::Simple;
use Try::Tiny;
use URI;

# ------------------------------------------------------------------------------
our $VERSION = 'v1.5';

# ------------------------------------------------------------------------------
my ( undef, $APP_DIR ) = fileparse($PROGRAM_NAME);

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
    new       => 'new.png',
    nonew     => 'nonew.png',
    error     => 'error.png',
    reconnect => 'reconnect.png',
    reload    => 'reload.png',
    quit      => 'quit.png',
    imap      => 'imap.png',
);
my ( $TRAYICON, $OPT, %APP_ICO );
my $PDS = Domain::PublicSuffix->new();
_app_init();
local $SIG{ALRM} = \&_mail_loop;
local $SIG{HUP}  = \&_app_reload;
alarm 1;

Gtk3->main;

# ------------------------------------------------------------------------------
sub _app_reload
{
    _disconnect_all();
    _app_init();
    alarm 1;
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
    state $locked = 0;

    return if $locked;
    ++$locked;

    my ( $errors, $unseen, @tooltip ) = ( 0, 0 );

    while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
        next unless $data->{mail_active};
        my ( $now, $error ) = (time);

        if ( $data->{mail_next} <= $now ) {
            undef $data->{mail_error};
            $error             = _imap_login( $name, $data )     unless $data->{imap};
            $error             = _check_one_imap( $name, $data ) unless $error;
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
        else {
            if ( $data->{detailed} ) {
                for my $i ( 0 .. $#{ $data->{mailboxes} } ) {
                    push @tooltip,
                        $name . q{[} . $data->{mailboxes}->[$i] . '] :: ' . $data->{mail_boxes}->[$i]->[1] . ' new';
                }
            }
            else {
                push @tooltip, $name . ' :: ' . $data->{mail_unseen} . ' new';
            }
            $unseen += $data->{mail_unseen};
        }
    }

    my $ico = 'nonew';
    if ($errors) {
        $ico = 'error';
    }
    elsif ($unseen) {
        $ico = 'new';
    }
    $TRAYICON->set_from_pixbuf( $APP_ICO{$ico}->get_pixbuf );
    $TRAYICON->set_tooltip_text( join "\n", @tooltip );

    alarm $SEC_IN_MIN;
    $locked = 0;
    return;
}

# ------------------------------------------------------------------------------
sub _check_one_imap
{
    my ( $name, $data ) = @_;

    my $error;

    $data->{mail_unseen} = 0;
    ++$data->{mail_count};

    _dbg( '%s :: checking mail, attempt %u from %u...', $name, $data->{mail_count}, $data->{reconnectafter} );

    for my $i ( 0 .. $#{ $data->{mailboxes} } ) {

        my ($unseen) = $data->{imap}->status( $data->{mail_boxes}->[$i]->[0] );

        if ( $data->{imap}->waserr ) {
            $error = $data->{imap}->errstr;
            last;
        }
        $unseen += 0;
        $data->{mail_unseen} += $unseen;
        $data->{mail_boxes}->[$i]->[1] = $unseen;
        _dbg( '%s[%s] :: OK, unseen: %u', $name, $data->{mailboxes}->[$i], $unseen );
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gsm;
        _dbg( '%s :: error %s', $name, $error );
    }
    else {
        if ( $data->{mail_count} >= $data->{reconnectafter} ) {
            _dbg( '%s :: max attempts (%u), logout', $name, $data->{mail_count} );
            $data->{imap}->logout;
            undef $data->{imap};
        }
    }

    return $error;
}

# ------------------------------------------------------------------------------
sub _imap_login
{
    my ( $name, $data ) = @_;

    my $error;

    $data->{opt}->{use_select_cache} = 0;
    $data->{mail_count} = 0;

    my $imap
        = Net::IMAP::Simple->new( $data->{host}, %{ $data->{opt} } );
    if ( !$imap ) {
        $error = sprintf '%s :: unable to connect (%s)', $name, $Net::IMAP::Simple::errstr;
        dbg( '%s', $error );
    }
    elsif ( !$imap->login( $data->{login}, $data->{password} ) ) {
        $error = sprintf '%s :: unable to login (%s)', $name, $imap->errstr;
        _dbg( '%s', $error );
        undef $imap;
    }
    else {
        _dbg( '%s :: login OK', $name );
        $data->{imap} = $imap;
    }
    return $error;
}

# ------------------------------------------------------------------------------
sub _create_tray_icon
{
    my $ti = Gtk3::StatusIcon->new;
    $ti->set_from_pixbuf( $APP_ICO{nonew}->get_pixbuf );

    $ti->signal_connect(

        button_press_event => sub {
            my ( undef, $event ) = @_;
            if ( $event->button == $BUTTON_RIGHT ) {
                my ( $menu, $item ) = ( Gtk3::Menu->new );
                while ( my ( $name, $data ) = each %{ $OPT->{imap} } ) {
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
                                $data->{imap}->logout if $data->{imap};
                                undef $data->{imap};
                            }
                        }
                    );
                    $item->show;
                    $menu->append($item);
                }

                $item = Gtk3::SeparatorMenuItem->new;
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Reconnect');
                $item->set_image( $APP_ICO{reconnect} );
                $item->signal_connect(
                    activate => sub {
                        _disconnect_all();
                        alarm 1;
                    }
                );
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Reload');
                $item->set_image( $APP_ICO{reload} );
                $item->signal_connect( activate => sub { _app_reload(); } );
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
        _confess( "Can not create icon from file \"%s\":\n %s", $file, $ERRNO );
    };
    return $ico;
}

# ------------------------------------------------------------------------------
sub _init_imap_data
{
    my ($data) = @_;

    $data->{interval}    = $OPT->{interval} unless $data->{interval};
    $data->{mail_next}   = time;
    $data->{mail_unseen} = 0;
    $data->{mail_total}  = 0;
    $data->{mail_active} = $data->{active} // 0;
    $data->{reconnectafter} //= $INT_MAX;
    undef $data->{imap};
    undef $data->{mail_error};

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
            return;
        }
    }
    elsif ( $ico eq 'online' ) {
        my $icon = get( sprintf $GET_FAVICON, $uri->host );
        $icon = get( sprintf $GET_FAVICON, $root ) unless $icon;
        if ($icon) {
            my ( $fh, $filename ) = tempfile( UNLINK => 1 );
            if ( !$fh ) {
                $data->{image} = $APP_ICO{imap};
                return;
            }
            binmode $fh, ':bytes';
            print {$fh} $icon;
            close $fh;
            $ico = $filename;
        }
        else {
            $data->{image} = $APP_ICO{imap};
            return;
        }
    }
    else {
        $ico = $IMAP_ICO_PATH . $ico;
    }
    $data->{image} = _icon_from_file($ico);
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
    _confess( '%s', 'Can not detect config file location' ) unless $config;

    _confess( 'Can not open file "%s": %s', $config, $ERRNO )
        unless open( my $fh, '<', $config );

    local $INPUT_RECORD_SEPARATOR = undef;
    my $cstring = <$fh>;
    close $fh;

    my $cfg;
    eval "\$cfg = $cstring;";
    _confess( 'Invalid config file "%s" (%s)', $config, $EVAL_ERROR )
        unless $cfg;
    $cfg = _convert( $cfg, q{_} );

    my $cerr = _check_config($cfg);
    _confess( '%s', $cerr ) if $cerr;
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
        $dest = $src;
    }
    return $dest;
}

# ------------------------------------------------------------------------------
sub _check_config
{
    my ($cfg) = @_;

    return 'No "OnClick" key' unless $cfg->{onclick};
    return 'Bad "Interval" key'
        if !$cfg->{interval}
        || $cfg->{interval} !~ /^\d+$/sm;

    return 'Invalid "IMAP" list' unless ref $cfg->{imap} eq 'HASH';

    while ( my ( $name, $data ) = each %{ $cfg->{imap} } ) {

        return "No \"host\" key in \"IMAP/$name\""     unless $data->{host};
        return "No \"password\" key in \"IMAP/$name\"" unless $data->{password};
        return "No \"login\" key in \"IMAP/$name\""    unless $data->{login};

        return "No mailboxes in \"IMAP/$name\""
            if ref $data->{mailboxes} ne 'ARRAY'
            || $#{ $data->{mailboxes} } < 0;

        @{ $data->{mailboxes} } = sort @{ $data->{mailboxes} };

        return "Invalid \"ReconnectAfter\" value in \"IMAP/$name\""
            if $data->{reconnectafter} && $data->{reconnectafter} !~ /^\d+$/sm;
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
        say sprintf '%s %s', _now(), sprintf $fmt, @data;
    }
    return;
}

# ------------------------------------------------------------------------------
sub _confess
{
    my ( $fmt, @data ) = @_;
    return confess sprintf "%s %s\n ", _now(), sprintf $fmt, @data;
}

# ------------------------------------------------------------------------------
sub _disconnect_all()
{
    if ( $OPT && ref $OPT->{imap} eq 'HASH' ) {
        while ( my ( undef, $data ) = each %{ $OPT->{imap} } ) {
            $data->{imap}->logout if $data->{imap};
            undef $data->{imap};
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

=item L<Encode>

=item L<Encode::IMAPUTF7>

=item L<English>

=item L<File::Basename>

=item L<File::Temp>

=item L<Gtk3>

=item L<LWP::Simple>

=item L<Net::IMAP::Simple>

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

Source code and issues can be found here:
 <https://github.com/klopp/imap-tray>

=cut

