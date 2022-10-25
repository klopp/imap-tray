#!/usr/bin/perl
# ------------------------------------------------------------------------------
#  Created on: 11.10.2015, 21:09:27
#  Author: Vsevolod Lutovinov <klopp@yandex.ru>
# ------------------------------------------------------------------------------
use utf8::all;
use open qw/:std :utf8/;
use Modern::Perl;

# ------------------------------------------------------------------------------
use Carp qw/confess/;
use Config::Find;
use Const::Fast;
use Domain::PublicSuffix;
use Encode qw/decode_utf8/;
use Encode::IMAPUTF7;
use English qw/-no_match_vars/;
use File::Basename;
use Gtk3 -init;
use Net::IMAP::Simple;
use Try::Tiny;
use URI;

# ------------------------------------------------------------------------------
our $VERSION = 'v1.0.4';
use DDP;

# ------------------------------------------------------------------------------
my ( undef, $APP_DIR ) = fileparse($PROGRAM_NAME);
const my $APP_ICO_PATH  => $APP_DIR . 'i/';
const my $IMAP_ICO_PATH => $APP_DIR . 'i/m/';
my %APP_ICO_SRC = (
    new       => 'new.png',
    nonew     => 'nonew.png',
    error     => 'error.png',
    reconnect => 'reconnect.png',
    quit      => 'quit.png',
    imap      => 'imap.png',
);
my %APP_ICO;
my $opt = _parse_config();
_init_app_ico();

my $PDS = Domain::PublicSuffix->new();
while ( my ( undef, $v ) = each %{ $opt->{imap} } ) {
    _init_imap_data($v);
}

my $trayicon = _create_tray_icon();
local $SIG{ALRM} = \&_mail_loop;
alarm 1;

Gtk3->main;

# ------------------------------------------------------------------------------
sub _mail_loop
{
    state $locked = 0;

    return if $locked;
    ++$locked;

    my ( $errors, $unseen, @tooltip ) = ( 0, 0 );
    while ( my ( $name, $data ) = each %{ $opt->{imap} } ) {
        next unless $data->{mail_active};

        my $error;
        $error = _imap_login( $name, $data )     unless $data->{imap};
        $error = _check_one_imap( $name, $data ) unless $error;

        if ($error) {
            push @tooltip, $name . ': ' . $error;
            $data->{mail_error} = 1;
            $errors++;
        }
        else {
            if ( $data->{detailed} ) {
                for my $i ( 0 .. $#{ $data->{mailboxes} } ) {
                    push @tooltip,
                        $name . q{/} . $data->{mailboxes}->[$i] . ' :: ' . $data->{mail_boxes}->[$i]->[1] . ' new';
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
    $trayicon->set_from_pixbuf( $APP_ICO{$ico}->get_pixbuf );
    $trayicon->set_tooltip_text( join "\n", @tooltip );

    alarm $opt->{interval};
    $locked = 0;
}

# ------------------------------------------------------------------------------
sub _check_one_imap
{
    my ( $name, $data ) = @_;

    my $error;

    $data->{mail_unseen} = 0;
    ++$data->{mail_count};

    say sprintf '%s :: checking mail, attempt %u from %u...', $name, $data->{mail_count}, $data->{reconnectafter}
        if $opt->{debug};

    for my $i ( 0 .. $#{ $data->{mailboxes} } ) {

        my ($unseen) = $data->{imap}->status( $data->{mail_boxes}->[$i]->[0] );

        if ( $data->{imap}->waserr ) {
            $error = $data->{imap}->errstr;
            last;
        }
        $unseen += 0;
        $data->{mail_unseen} += $unseen;
        $data->{mail_boxes}->[$i]->[1] = $unseen;
        say sprintf '%s/%s :: OK, unseen: %u', $name, $data->{mailboxes}->[$i], $unseen
            if $opt->{debug};
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gsm;
        say sprintf '%s :: error %s', $name, $error
            if $opt->{debug};
    }
    else {
        if ( $data->{mail_count} >= $data->{reconnectafter} ) {
            say sprintf '%s :: max attempts (%u), logout', $name, $data->{mail_count}
                if $opt->{debug};
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
        say $error if $opt->{debug};
    }
    elsif ( !$imap->login( $data->{login}, $data->{password} ) ) {
        $error = sprintf '%s :: unable to login (%s)', $name, $imap->errstr;
        say $error if $opt->{debug};
        undef $imap;
    }
    else {
        say sprintf '%s :: login OK', $name if $opt->{debug};
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
            if ( $event->button == 3 ) {
                my ( $menu, $item ) = ( Gtk3::Menu->new );

                while ( my ( $name, $data ) = each %{ $opt->{imap} } ) {
                    $item = Gtk3::ImageMenuItem->new($name);
                    my $dest = $data->{image}->get_pixbuf->copy;
                    if ( !$data->{mail_active} ) {
                        $dest->saturate_and_pixelate( $dest, 0.01, 1 );
                    }
                    elsif ( $data->{mail_error} ) {
                        $dest->saturate_and_pixelate( $dest, 10, 1 );
                    }
                    my $image = Gtk3::Image->new_from_pixbuf($dest);
                    $item->set_image($image);
                    $item->signal_connect(
                        activate => sub {
                            $data->{mail_active} ^= 1;
                            unless ( $data->{active} ) {
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
                        while ( my ( undef, $data ) = each %{ $opt->{imap} } ) {
                            $data->{imap}->logout if $data->{imap};
                            undef $data->{imap};
                        }
                        alarm 1;
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
            elsif ( $event->button == 1 ) {
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
    if ( ref $opt->{onclick} eq 'CODE' ) {
        return &{ $opt->{onclick} };
    }
    return system $opt->{onclick};
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
        confess sprintf "Can not create icon from file \"%s\:\n %s", $file, $ERRNO;
    };
    return $ico;
}

# ------------------------------------------------------------------------------
sub _init_imap_data
{
    my ($data) = @_;
    my $ico = $data->{icon};
    unless ($ico) {
        my $uri  = URI->new( 'http://' . $data->{host} );
        my $root = $PDS->get_root_domain( $uri->host );
        if ( -f $IMAP_ICO_PATH . $root . '.png' ) {
            $ico = $root . '.png';
        }
        else {
            $data->{image} = $APP_ICO{imap};
            return;
        }
    }
    $data->{image}       = _icon_from_file( $IMAP_ICO_PATH . $ico );
    $data->{mail_unseen} = 0;
    $data->{mail_total}  = 0;
    $data->{mail_error}  = 0;
    $data->{mail_active} = $data->{active} // 0;
    $data->{reconnectafter} //= ~0 - 1;
    undef $data->{imap};

    for ( @{ $data->{mailboxes} } ) {
        push @{ $data->{mail_boxes} }, [ Encode::IMAPUTF7::encode( 'IMAP-UTF-7', $_ ), 0 ];
    }
}

# ------------------------------------------------------------------------------
sub _init_app_ico
{
    while ( my ( $k, $v ) = each %{ $opt->{icons} } ) {
        $APP_ICO_SRC{$k} = $v;
    }
    while ( my ( $k, $v ) = each %APP_ICO_SRC ) {
        $APP_ICO{$k} = _icon_from_file( $APP_ICO_PATH . $v );
    }
}

# ------------------------------------------------------------------------------
sub _parse_config
{
    my $config = $ARGV[0] ? $ARGV[0] : Config::Find->find;
    confess "Can not detect config file location\n" unless $config;
    my $cfg = do($config);
    confess "Invalid config file \"$config\"\n"
        unless $cfg;

    $cfg = _convert( $cfg, q{_} );   
   
    my $cerr = _check_config($cfg);
    confess $cerr if $cerr;
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
        $dest = decode_utf8($src);
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

        return 'No "host" key in "IMAP" list'          unless $data->{host};
        return "No \"password\" key in \"IMAP/$name\"" unless $data->{password};
        return "No \"login\" key in \"IMAP/$name\""    unless $data->{login};

        return "No mailboxes in \"IMAP/$name\""
            if ref $data->{mailboxes} ne 'ARRAY'
            || $#{ $data->{mailboxes} } < 0;

        if ( defined $data->{reconnectafter}
            && $data->{reconnectafter} !~ /^\d+$/sm )
        {
            return "Invalid \"ReconnectAfter\" value in \"IMAP/$name\"";
        }
    }
    return;
}

# ------------------------------------------------------------------------------
END {
    if ( $opt && ref $opt->{imap} eq 'HASH' ) {
        while ( my ( undef, $data ) = each %{ $opt->{imap} } ) {
            $data->{imap}->logout if $data->{imap};
            undef $data->{imap};
        }
    }
}

# ------------------------------------------------------------------------------

__END__

=pod

=head1 SYNOPSIS

./imap-tray.pl [config_file]

=cut

