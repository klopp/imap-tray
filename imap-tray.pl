#!/usr/bin/perl
# ------------------------------------------------------------------------------
#  Created on: 11.10.2015, 21:09:27
#  Author: Vsevolod Lutovinov <klopp@yandex.ru>
# ------------------------------------------------------------------------------
use utf8::all;
use open qw/:std :utf8/;
use Modern::Perl;

# ------------------------------------------------------------------------------
use Gtk2 qw/-init/;
use FindBin qw/$RealScript $RealBin/;
use Encode::IMAPUTF7;
use Net::IMAP::Simple;
use Data::Recursive::Encode;
use Data::Printer;
use LWP::Simple;
use Try::Catch;
use URI;

# ------------------------------------------------------------------------------
use version;
our $VERSION = 'v1.0.1';
my $FAVICON       = 'http://www.google.com/s2/favicons?domain=%s';
my %DEFAULT_ICONS = (
    qr/yahoo.com$/      => 'yahoo.com.png',
    qr/yandex.com$/     => 'yandex.com.png',
    qr/mail.ru$/        => 'mail.ru.png',
    qr/rambler.ru$/     => 'rambler.ru.png',
    qr/hotmail.com$/    => 'hotmail.com.png',
    qr/googlemail.com$/ => 'googlemail.com.png',
);

# ------------------------------------------------------------------------------
my $locked;
my $config = ( $RealScript =~ /^(.+)[.][^.]+$/ ? $1 : $RealScript ) . q{.conf};
$config = "$RealBin/$config";
my $ipath = "$RealBin/i";
$ARGV[0] and $config = $ARGV[0];

my $opt    = Data::Recursive::Encode->decode_utf8( do($config) );
my $cerror = _check_config();
die "Invalid config file \"$config\": $cerror\n" if $cerror;

# ------------------------------------------------------------------------------
for my $imap ( @{ $opt->{'IMAP'} } ) {

    my $domain = $imap->{host};
    $domain =~ s/:.*$//s;

    if ( !$imap->{'icon'} ) {
        for ( keys %DEFAULT_ICONS ) {
            $imap->{'icon'} = $DEFAULT_ICONS{$_}, last
                if $domain =~ $_;
        }
    }

    if ( $imap->{'icon'} ) {
        try {
            $imap->{'image'}
                = Gtk2::Image->new_from_file("$ipath/m/$imap->{'icon'}");
        }
        catch {
            say $_ if $opt->{'Debug'};
        };
    }

    if ( !$imap->{'image'} ) {

        my $icofile = "$ipath/m/$domain.icon";

        if ( !-f $icofile ) {

            my $icon = get( sprintf $FAVICON, $domain );
            if ($icon) {
                if ( open my $f, '>', $icofile ) {
                    binmode $f, ':bytes';
                    print $f $icon;
                    close $f;
                    try {
                        $imap->{'image'} = Gtk2::Image->new_from_file($icofile);
                    }
                    catch {
                        say $_ if $opt->{'Debug'};
                    };
                }
            }
        }
        else {
            try {
                $imap->{'image'} = Gtk2::Image->new_from_file($icofile);
            }
            catch {
                say $_ if $opt->{'Debug'};
            };
        }

        $imap->{'image'}
            = Gtk2::Image->new_from_file( "$ipath/m/" . $opt->{'IconMail'} )
            unless $imap->{'image'};
    }
}

# ------------------------------------------------------------------------------
my $icon_quit
    = Gtk2::Image->new_from_file( "$ipath/" . $opt->{'IconQuit'} );
my $icon_no_new = [
    Gtk2::Gdk::Pixbuf->new_from_file( "$ipath/" . $opt->{'IconNoNew'} ),
    $opt->{'IconNoNew'}
];
my $icon_new = [
    Gtk2::Gdk::Pixbuf->new_from_file( "$ipath/" . $opt->{'IconNew'} ),
    $opt->{'IconNew'}
];
my $icon_error = [
    Gtk2::Gdk::Pixbuf->new_from_file( "$ipath/" . $opt->{'IconError'} ),
    $opt->{'IconError'}
];
my $icon_current = q{};

my $trayicon = Gtk2::StatusIcon->new;
$trayicon->signal_connect(
    'button_press_event' => sub {
        my ( undef, $event ) = @_;
        if ( $event->button == 3 ) {
            my ( $menu, $item ) = ( Gtk2::Menu->new );

            for my $imap ( @{ $opt->{'IMAP'} } ) {

                #my $label = $imap->{'name'};
                #$label = "<s>$label</s>" unless $imap->{'active'};
                #$label = '[*] ' . $label if $imap->{'active'};

                #if ( $imap->{'error'} ) {
                #    $label = $label . ' !';
                #}
                #elsif ( $imap->{'new'} ) {
                #    $label = $label . ' ' . $imap->{'new'};
                #}

                $item = Gtk2::ImageMenuItem->new($imap->{'name'});
#                my $src = $imap->{'image'}->get_pixbuf->copy;
                my $dest = $imap->{'image'}->get_pixbuf->copy;
                if( !$imap->{'active'})
                {
                    $dest->saturate_and_pixelate( $dest, 0.01, 1 );
                }
                elsif ( $imap->{'error'} ) {
                    $dest->saturate_and_pixelate( $dest, 10, 1 );
                }
                
#                my $src = $imap->{'image'}->get_pixbuf->copy;
#                my $dest = $imap->{'image'}->get_pixbuf->copy;
#                $src->saturate_and_pixelate( $dest, 10, 1 );
                
                my $image = Gtk2::Image->new_from_pixbuf($dest);
                $item->set_image( $image );
                $item->signal_connect( activate =>
                        sub { $imap->{'active'} = $imap->{'active'} ? 0 : 1 } );
                $item->show;
                $menu->append($item);
            }

            $item = Gtk2::SeparatorMenuItem->new;
            $item->show;
            $menu->append($item);

            $item = Gtk2::ImageMenuItem->new('Quit');
            $item->set_image( $icon_quit );
            $item->signal_connect( activate => sub { Gtk2->main_quit } );
            $item->show;
            $menu->append($item);

            $menu->show_all;
            $menu->popup( undef, undef, undef, undef, $event->button,
                $event->time );
        }
        elsif ( $event->button == 1 ) {
            _on_click( $opt->{'OnClick'} );
        }
        1;
    }
);

local $SIG{'ALRM'} = sub {

    if ( !$locked ) {

        $locked++;
        my $total  = 0;
        my $errors = 0;
        my @tooltip;

        for ( @{ $opt->{'IMAP'} } ) {

            next unless $_->{'active'};

            my $error;
            $_->{'error'} = 0;
            $error = _imap_login($_)     unless $_->{'imap'};
            $error = _check_one_imap($_) unless $error;

            if ($error) {
                push @tooltip, $_->{'name'} . ': ' . $error;
                $_->{'error'} = 1;
                $errors++;
            }
            else {
                if ( $_->{'detailed'} ) {
                    if ( $_->{'new'} ) {
                        for my $i ( 0 .. $#{ $_->{'mailboxes'} } ) {
                            push @tooltip,
                                  $_->{'name'} . '/'
                                . $_->{'mailboxes'}->[$i] . ': '
                                . $_->{'emailboxes'}->[$i]->[1] . ' new'
                                if $_->{'emailboxes'}->[$i]->[1];
                        }
                    }
                    else {
                        push @tooltip, $_->{'name'} . ': 0 new';

                    }
                }
                else {
                    push @tooltip, $_->{'name'} . ': ' . $_->{'new'} . ' new';
                }
                $total += $_->{'new'};
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

        push @tooltip, $opt->{'ShowHelp'} if $opt->{'ShowHelp'};

        $trayicon->set_tooltip( join( "\n", @tooltip ) );
        $locked = 0;
    }

    alarm $opt->{'Interval'};
};

alarm 1;
Gtk2->main;

# ------------------------------------------------------------------------------
sub _dialog {
    my $msg    = shift;
    my $dialog = Gtk2::Dialog->new(
        $msg,
        undef, 'destroy-with-parent'

            #        , 'gtk-ok' => 'reject'
    );
    my $label = Gtk2::Label->new( $msg x 10 );
    $dialog->get_content_area()->add($label);

    #    $dialog->signal_connect( response => sub { Gtk2->main_quit } );
    $dialog->show_all;
}

# ------------------------------------------------------------------------------
sub _on_click {

    # TODO XZ...
    my ($cmd) = @_;
    return system $cmd;
}

# ------------------------------------------------------------------------------
sub _set_icon {
    my ($icon) = @_;

    if ( $icon->[1] ne $icon_current ) {
        $trayicon->set_from_pixbuf( $icon->[0] );
        $icon_current = $icon->[1];
    }
    return;
}

# ------------------------------------------------------------------------------
sub _imap_login {
    my ($conf) = @_;

    my $error;

    say $conf->{'name'} . ' login...' if $opt->{'Debug'};

    $conf->{'opt'}->{'timeout'} = $opt->{'Interval'}
        unless defined $conf->{'opt'}->{'timeout'};
    $conf->{'opt'}->{'use_select_cache'} = 0;
    $conf->{'stat_count'} = 0;

    my $imap
        = Net::IMAP::Simple->new( $conf->{'host'}, %{ $conf->{'opt'} } );
    if ( !$imap ) {
        $error = 'Unable to connect: ' . $Net::IMAP::Simple::errstr;
        say $error if $opt->{'Debug'};
    }
    elsif ( !$imap->login( $conf->{'login'}, $conf->{'password'} ) ) {
        $error = 'Unable to login: ' . $imap->errstr;
        say $error if $opt->{'Debug'};
        undef $imap;
    }
    else {
        $conf->{'imap'} = $imap;

        if ( !$conf->{'emailboxes'} ) {
            $conf->{'emailboxes'} = [];

            for my $i ( 0 .. $#{ $conf->{'mailboxes'} } ) {
                $conf->{'emailboxes'}->[$i]->[0]
                    = Encode::IMAPUTF7::encode( 'IMAP-UTF-7',
                    $conf->{'mailboxes'}->[$i] );
            }
        }
    }
    return $error;
}

# ------------------------------------------------------------------------------
sub _check_one_imap {
    my ($conf) = @_;

    my $error;

    $conf->{'new'} = 0;
    say $conf->{'name'} . q{:} if $opt->{'Debug'};

    for ( 0 .. $#{ $conf->{'mailboxes'} } ) {
        my ( $unseen, $recent, $msgs )
            = $conf->{'imap'}->status( $conf->{'emailboxes'}->[$_]->[0] );

        if ( $conf->{'imap'}->waserr ) {
            $error = $conf->{'imap'}->errstr;
            undef $conf->{'imap'};
            last;
        }

        $unseen ||= 0;
        $recent ||= 0;
        $msgs   ||= 0;
        say " $conf->{'mailboxes'}->[$_]: $unseen, $recent, $msgs"
            if $opt->{'Debug'};
        $conf->{'new'} += $unseen;
        $conf->{'emailboxes'}->[$_]->[1] = $unseen;
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gs;
        say $error if $opt->{'Debug'};
        $conf->{'new'} = 0;
        $conf->{'imap'}->logout;
        undef $conf->{'imap'};
    }
    else {
        $conf->{'stat_count'}++;

        say "$conf->{'stat_count'} / $conf->{'reloginafter'}"
            if $conf->{'reloginafter'} && $opt->{'Debug'};

        if (   $conf->{'reloginafter'}
            && $conf->{'stat_count'} > $conf->{'reloginafter'} )
        {
            $conf->{'imap'}->logout;
            undef $conf->{'imap'};
        }
    }

    return $error;
}

# ------------------------------------------------------------------------------
sub _check_config {
    return 'bad format' unless ref $opt eq 'HASH';

    return 'no "OnClick" key' unless $opt->{'OnClick'};
    return 'bad "Interval" key'
        if !$opt->{'Interval'}
        || $opt->{'Interval'} !~ /^\d+$/;
    return 'invalid "IMAP" list' unless ref $opt->{'IMAP'} eq 'ARRAY';

    for ( @{ $opt->{'IMAP'} } ) {

        return 'no "host" key in "IMAP" list' unless $_->{'host'};
        $_->{'name'} ||= $_->{'host'};
        my $name = $_->{'name'};
        return "no \"password\" key in \"IMAP/$name\"" unless $_->{'password'};
        return "no \"login\" key in \"IMAP/$name\""    unless $_->{'login'};
        return "no mailboxes in \"IMAP/$name\""
            if ref $_->{'mailboxes'} ne 'ARRAY'
            || $#{ $_->{'mailboxes'} } < 0;

        if ( defined $_->{'reloginafter'}
            && $_->{'reloginafter'} !~ /^\d+$/ )
        {
            return "invalid \"reloginafter\" value in \"IMAP/$name\"";
        }
    }

    return;
}

# ------------------------------------------------------------------------------
END {
    if ( $opt && ref $opt->{'IMAP'} eq 'ARRAY' ) {
        for ( @{ $opt->{'IMAP'} } ) {
            $_->{'imap'}->logout if $_->{'imap'};
            undef $_->{'imap'};
        }
    }
}

# ------------------------------------------------------------------------------

__END__

=pod

=head1 SYNOPSIS

./imap-tray.pl [config_file]

=head1 TODO

1. Lowercase config keys?
2. PID checking?
3. SIGHUP handling?
N. ?

=cut

