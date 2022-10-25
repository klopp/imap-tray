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
use English qw/-no_match_vars/;
use File::Basename;
use Gtk3 -init;
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

#exit;
#p $opt->{imap};

my $trayicon = _create_tray_icon();
Gtk3->main;

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

=pod
            for my $imap ( @{ $cfg->{imap} } ) {

                my $label = $imap->{name};
                $label .= " ($imap->{new})" if $imap->{new};
                $item = Gtk3::ImageMenuItem->new($label);
                my $dest = $imap->{image}->get_pixbuf->copy;
                if ( !$imap->{active} ) {
                    $dest->saturate_and_pixelate( $dest, 0.01, 1 );
                }
                elsif ( $imap->{error} ) {
                    $dest->saturate_and_pixelate( $dest, 10, 1 );
                }

                my $image = Gtk3::Image->new_from_pixbuf($dest);
                $item->set_image($image);
                $item->signal_connect( activate => sub { $imap->{active} = $imap->{active} ? 0 : 1 } );
                $item->show;
                $menu->append($item);
            }
=cut

                $item = Gtk3::SeparatorMenuItem->new;
                $item->show;
                $menu->append($item);

                $item = Gtk3::ImageMenuItem->new('Reconnect');
                $item->set_image( $APP_ICO{reconnect} );
                $item->signal_connect(
                    activate => sub {
                        while ( my ( undef, $data ) = each %{ $opt->{imap} } ) {
                            $data->{mail_check} = $data->{reconnectafter} + 1;
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
        return &$opt->{onclick};
    }
    return system $opt->{onclick};
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
    $data->{image}       = Gtk3::Image->new_from_file( $IMAP_ICO_PATH . $ico );
    $data->{mail_check}  = 0;
    $data->{mail_unread} = 0;
    $data->{mail_total}  = 0;
    $data->{mail_active} = $data->{active} // 0;
}

# ------------------------------------------------------------------------------
sub _init_app_ico
{
    while ( my ( $k, $v ) = each %{ $opt->{icons} } ) {
        $APP_ICO_SRC{$k} = $v;
    }
    while ( my ( $k, $v ) = each %APP_ICO_SRC ) {
        try {
            my $pb = Gtk3::Gdk::Pixbuf->new_from_file( $APP_ICO_PATH . $v );
            $APP_ICO{$k} = Gtk3::Image->new_from_pixbuf($pb);
        }
        catch {
            confess sprintf "Can not create icon from file \"%s%s\:\n%s", $APP_ICO_PATH, $v, $ERRNO;
        }
    }
}

# ------------------------------------------------------------------------------
sub _parse_config
{
    my $config = Config::Find->find;
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

=pod

# ------------------------------------------------------------------------------

use Encode::IMAPUTF7;
use Encode qw/decode_utf8/;
use Gtk3 qw/-init/;
use Net::IMAP::Simple;
use LWP::Simple;
use Try::Tiny;

const my $FAVICON       => 'http://www.google.com/s2/favicons?domain=%s';
const my %DEFAULT_ICONS => (
    qr/yahoo.com$/      => 'yahoo.com.png',
    qr/yandex.com$/     => 'yandex.com.png',
    qr/mail.ru$/        => 'mail.ru.png',
    qr/rambler.ru$/     => 'rambler.ru.png',
    qr/hotmail.com$/    => 'hotmail.com.png',
    qr/outlook.com$/    => 'outlook.com.png',
    qr/googlemail.com$/ => 'googlemail.com.png',
);


my $locked;
my $config = ( $RealScript =~ /^(.+)[.][^.]+$/ ? $1 : $RealScript ) . q{.conf};
$config = "$RealBin/$config";
my $ipath = "$RealBin/i";
$ARGV[0] and $config = $ARGV[0];

my $cfg    = _lowerkeys( do($config) );
my $cerror = _check_config();
die "Invalid config file \"$config\": $cerror\n" if $cerror;

if ( $cfg->{debug} ) {
    eval { use DDP; };
}

# ------------------------------------------------------------------------------
for my $imap ( @{ $cfg->{imap} } ) {

    my $domain = $imap->{host};
    $domain =~ s/:.*$//s;

    if ( !$imap->{icon} ) {
        for ( keys %DEFAULT_ICONS ) {
            $imap->{icon} = $DEFAULT_ICONS{$_}, last
                if $domain =~ $_;
        }
    }

    if ( $imap->{icon} ) {
        try {
            $imap->{image} = Gtk3::Image->new_from_file("$ipath/m/$imap->{icon}");
        }
        catch {
            say $_ if $cfg->{debug};
        };
    }

    if ( !$imap->{image} ) {

        my $icofile = "$ipath/m/$domain.icon";

        if ( !-f $icofile ) {

            my $icon = get( sprintf $FAVICON, $domain );
            if ($icon) {
                if ( open my $f, '>', $icofile ) {
                    binmode $f, ':bytes';
                    print {$f} $icon;
                    close $f;
                    try {
                        $imap->{image} = Gtk3::Image->new_from_file($icofile);
                    }
                    catch {
                        say $_ if $cfg->{debug};
                    };
                }
            }
        }
        else {
            try {
                $imap->{image} = Gtk3::Image->new_from_file($icofile);
            }
            catch {
                say $_ if $cfg->{debug};
            };
        }

        $imap->{image} = Gtk3::Image->new_from_file( "$ipath/m/" . $cfg->{iconmail} )
            unless $imap->{image};
    }
}

# ------------------------------------------------------------------------------
my $icon_quit    = Gtk3::Image->new_from_file( "$ipath/" . $cfg->{iconquit} );
my $icon_relogin = Gtk3::Image->new_from_file( "$ipath/" . $cfg->{iconrelogin} );
my $icon_no_new  = [ Gtk3::Gdk::Pixbuf->new_from_file( "$ipath/" . $cfg->{iconnonew} ), $cfg->{iconnonew} ];
my $icon_new     = [ Gtk3::Gdk::Pixbuf->new_from_file( "$ipath/" . $cfg->{iconnew} ),   $cfg->{iconnew} ];
my $icon_error   = [ Gtk3::Gdk::Pixbuf->new_from_file( "$ipath/" . $cfg->{iconerror} ), $cfg->{iconerror} ];
my $icon_current = q{};

my $trayicon = Gtk3::StatusIcon->new;
$trayicon->signal_connect(
    'button_press_event' => sub {
        my ( undef, $event ) = @_;
        if ( $event->button == 3 ) {
            my ( $menu, $item ) = ( Gtk3::Menu->new );

            for my $imap ( @{ $cfg->{imap} } ) {

                my $label = $imap->{name};
                $label .= " ($imap->{new})" if $imap->{new};
                $item = Gtk3::ImageMenuItem->new($label);
                my $dest = $imap->{image}->get_pixbuf->copy;
                if ( !$imap->{active} ) {
                    $dest->saturate_and_pixelate( $dest, 0.01, 1 );
                }
                elsif ( $imap->{error} ) {
                    $dest->saturate_and_pixelate( $dest, 10, 1 );
                }

                my $image = Gtk3::Image->new_from_pixbuf($dest);
                $item->set_image($image);
                $item->signal_connect( activate => sub { $imap->{active} = $imap->{active} ? 0 : 1 } );
                $item->show;
                $menu->append($item);
            }

            $item = Gtk3::SeparatorMenuItem->new;
            $item->show;
            $menu->append($item);

            $item = Gtk3::ImageMenuItem->new('Reconnect');
            $item->set_image($icon_relogin);
            $item->signal_connect(
                activate => sub {
                    for ( @{ $cfg->{imap} } ) {
                        $_->{stat_count} = $_->{reconnectafter} + 1;
                    }
                }
            );
            $item->show;
            $menu->append($item);

            $item = Gtk3::ImageMenuItem->new('Quit');
            $item->set_image($icon_quit);
            $item->signal_connect( activate => sub { Gtk3->main_quit } );
            $item->show;
            $menu->append($item);

            $menu->show_all;
            $menu->popup( undef, undef, undef, undef, $event->button, $event->time );
        }
        elsif ( $event->button == 1 ) {
            _on_click( $cfg->{onclick} );
        }
        1;
    }
);

local $SIG{ALRM} = sub {

    if ( !$locked ) {

        $locked++;
        my $total  = 0;
        my $errors = 0;
        my @tooltip;

        for ( @{ $cfg->{imap} } ) {

            next unless $_->{active};

            my $error;
            $_->{error} = 0;
            $error      = _imap_login($_)     unless $_->{imap};
            $error      = _check_one_imap($_) unless $error;

            if ($error) {
                push @tooltip, $_->{name} . ': ' . $error;
                $_->{error} = 1;
                $errors++;
            }
            else {
                if ( $_->{detailed} ) {
                    if ( $_->{new} ) {
                        for my $i ( 0 .. $#{ $_->{mailboxes} } ) {
                            push @tooltip,
                                $_->{name} . q{/} . $_->{mailboxes}->[$i] . ': ' . $_->{emailboxes}->[$i]->[1] . ' new'
                                if $_->{emailboxes}->[$i]->[1];
                        }
                    }
                    else {
                        push @tooltip, $_->{name} . ': 0 new';

                    }
                }
                else {
                    push @tooltip, $_->{name} . ': ' . $_->{new} . ' new';
                }
                $total += $_->{new};
            }
        }

        if ($errors) {
            _set_icon($icon_error);
        }
        elsif ($total) {
            _set_icon($icon_new);
        }
        else {
            _set_icon($icon_no_new);
        }

        push @tooltip, $cfg->{showhelp} if $cfg->{showhelp};

        $trayicon->set_tooltip_text( join "\n", @tooltip );
        $locked = 0;
    }

    alarm $cfg->{interval};
};

alarm 1;
Gtk3->main;

# ------------------------------------------------------------------------------
sub _on_click
{

    # TODO XZ...
    my ($todo) = @_;

    if ( ref $todo eq 'CODE' ) {
        return &$todo;
    }
    return system $todo;
}

# ------------------------------------------------------------------------------
sub _set_icon
{
    my ($icon) = @_;

    if ( $icon->[1] ne $icon_current ) {
        $trayicon->set_from_pixbuf( $icon->[0] );
        $icon_current = $icon->[1];
    }
    return;
}

# ------------------------------------------------------------------------------
sub _imap_login
{
    my ($conf) = @_;

    my $error;

    say $conf->{name} . ' connect...' if $cfg->{debug};

    $conf->{opt}->{timeout} = $cfg->{Interval}
        unless defined $conf->{opt}->{timeout};
    $conf->{opt}->{use_select_cache} = 0;
    $conf->{stat_count} = 0;

    if ( $cfg->{debug} ) {
        say $conf->{host};
        p $conf->{opt};
    }

    my $imap
        = Net::IMAP::Simple->new( $conf->{host}, %{ $conf->{opt} } );
    if ( !$imap ) {
        $error = 'Unable to connect: ' . $Net::IMAP::Simple::errstr;
        say $error if $cfg->{debug};
    }
    elsif ( !$imap->login( $conf->{login}, $conf->{password} ) ) {
        $error = 'Unable to login: ' . $imap->errstr;
        say $error if $cfg->{debug};
        undef $imap;
    }
    else {
        $conf->{imap} = $imap;

        if ( !$conf->{emailboxes} ) {
            $conf->{emailboxes} = [];

            for my $i ( 0 .. $#{ $conf->{mailboxes} } ) {
                $conf->{emailboxes}->[$i]->[0] = Encode::IMAPUTF7::encode( 'IMAP-UTF-7', $conf->{mailboxes}->[$i] );
            }
        }
    }
    return $error;
}

# ------------------------------------------------------------------------------
sub _check_one_imap
{
    my ($conf) = @_;

    my $error;

    $conf->{new} = 0;
    say $conf->{name} . q{:} if $cfg->{debug};

    for ( 0 .. $#{ $conf->{mailboxes} } ) {
        my ( $unseen, undef, $total )
            = $conf->{imap}->status( $conf->{emailboxes}->[$_]->[0] );

        if ( $conf->{imap}->waserr ) {
            $error = $conf->{imap}->errstr;
            undef $conf->{imap};
            last;
        }

        $unseen += 0;
        $total  += 0;
        say " [$conf->{mailboxes}->[$_]] total=>$total, unseen=>$unseen"
            if $cfg->{debug};
        $conf->{new} += $unseen;
        $conf->{emailboxes}->[$_]->[1] = $unseen;
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gs;
        say $error if $cfg->{debug};
        $conf->{new} = 0;
        $conf->{imap}->logout;
        undef $conf->{imap};
    }
    else {
        $conf->{stat_count}++;

        say "Attempt $conf->{stat_count} from $conf->{reconnectafter}"
            if $conf->{reconnectafter} && $cfg->{debug};

        if (   $conf->{reconnectafter}
            && $conf->{stat_count} > $conf->{reconnectafter} )
        {
            say "Reconnect after $conf->{stat_counts} attempts..."
                if $cfg->{debug};
            $conf->{imap}->logout;
            undef $conf->{imap};
        }
    }

    return $error;
}

# ------------------------------------------------------------------------------
sub _check_config
{
    return 'bad format' unless ref $cfg eq 'HASH';

    return 'no "onclick" key' unless $cfg->{onclick};
    return 'bad "interval" key'
        if !$cfg->{interval}
        || $cfg->{interval} !~ /^\d+$/;
    return 'invalid "IMAP" list' unless ref $cfg->{imap} eq 'ARRAY';

    for ( @{ $cfg->{imap} } ) {

        return 'no "host" key in "IMAP" list' unless $_->{host};
        $_->{name} ||= $_->{host};
        my $name = $_->{name};
        return "no \"password\" key in \"IMAP/$name\"" unless $_->{password};
        return "no \"login\" key in \"IMAP/$name\""    unless $_->{login};
        return "no mailboxes in \"IMAP/$name\""
            if ref $_->{mailboxes} ne 'ARRAY'
            || $#{ $_->{mailboxes} } < 0;

        @{ $_->{mailboxes} }
            = map { $_ = decode_utf8($_) } @{ $_->{mailboxes} };

        if ( defined $_->{reconnectafter}
            && $_->{reconnectafter} !~ /^\d+$/ )
        {
            return "invalid \"reconnectafter\" value in \"IMAP/$name\"";
        }
    }

    return;
}

# ------------------------------------------------------------------------------
sub _lowerkeys
{
    my ($src) = @_;

    my $dest;
    if ( ref $src eq 'ARRAY' ) {
        @{$dest} = map { _lowerkeys($_) } @{$src};
    }
    elsif ( ref $src eq 'HASH' ) {
        %{$dest} = map { lc $_ => _lowerkeys( $src->{$_} ) } keys %{$src};
    }
    else {
        $dest = $src;
    }

    return $dest;
}

# ------------------------------------------------------------------------------
END {
    if ( $cfg && ref $cfg->{imap} eq 'ARRAY' ) {
        for ( @{ $cfg->{imap} } ) {
            $_->{imap}->logout if $_->{imap};
            undef $_->{imap};
        }
    }
}
=cut

# ------------------------------------------------------------------------------

__END__

=pod

=head1 SYNOPSIS

./imap-tray.pl [config_file]

=head1 TODO

* PID checking?
* SIGHUP handling?
* IDN support?
* ?

=cut

