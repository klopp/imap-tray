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
use Net::IMAP::Simple;
use Encode::IMAPUTF7;
use Data::Recursive::Encode;

# ------------------------------------------------------------------------------
my $locked;
my $DEBUG;
my $config = ( $RealScript =~ /^(.+)[.][^.]+$/ ? $1 : $RealScript ) . q{.conf};
$config = "$RealBin/$config";
$ARGV[0] and $config = $ARGV[0];
my $opt    = Data::Recursive::Encode->decode_utf8( do($config) );
my $cerror = _check_config();
die "Invalid config file \"$config\": $cerror\n" if $cerror;
$DEBUG = $opt->{'Debug'};

my $icon_no_new = [ Gtk2::Gdk::Pixbuf->new_from_file( $opt->{IconNoNew} ),
    $opt->{IconNoNew} ];
my $icon_new
    = [ Gtk2::Gdk::Pixbuf->new_from_file( $opt->{IconNew} ), $opt->{IconNew} ];
my $icon_error = [ Gtk2::Gdk::Pixbuf->new_from_file( $opt->{IconError} ),
    $opt->{IconError} ];
my $icon_current = q{};

my $trayicon = Gtk2::StatusIcon->new;
$trayicon->signal_connect(
    'button_press_event' => sub {
        my ( undef, $event ) = @_;
        if ( $event->button eq 3 ) {
            Gtk2->main_quit;
        }
        elsif ( $event->button eq 1 ) {
            _on_click( $opt->{'OnClick'} );
        }
        1;
    }
);

local $SIG{'ALRM'} = sub {

    unless ($locked) {

        $locked++;
        my $total  = 0;
        my $errors = 0;
        my @tooltip;

        for ( @{ $opt->{'IMAP'} } ) {

            next unless $_->{'active'};

            my $error = _imap_login($_) unless $_->{'imap'};
            $error = _check_one_imap($_) unless $error;

            if ($error) {
                push @tooltip, $_->{'name'} . ': ' . $error;
                $errors++;
            }
            else {
                push @tooltip, $_->{'name'} . ': ' . $_->{'new'} . ' new';
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
        $trayicon->set_tooltip( join( "\n", @tooltip ) );
        $locked = 0;
    }

    alarm( $opt->{'Interval'} );
};
alarm 1;
Gtk2->main;

# ------------------------------------------------------------------------------
sub _on_click {

    # TODO XZ...
    my ($cmd) = @_;
    `$cmd`;
}

# ------------------------------------------------------------------------------
sub _set_icon {
    my ($icon) = @_;

    if ( $icon->[1] ne $icon_current ) {
        $trayicon->set_from_pixbuf( $icon->[0] );
        $icon_current = $icon->[1];
    }
}

# ------------------------------------------------------------------------------
sub _imap_login {
    my ($conf) = @_;

    my $error;

    say $conf->{'name'} . ' login...' if $DEBUG;

    my $imap
        = Net::IMAP::Simple->new( $conf->{'host'}, %{ $conf->{'opt'} } );
    if ( !$imap ) {
        $error = 'Unable to connect: ' . $Net::IMAP::Simple::errstr;
    }
    elsif ( !$imap->login( $conf->{'login'}, $conf->{'password'} ) ) {
        $error = 'Unable to login: ' . $imap->errstr;
        undef $imap;
    }
    else {
        $conf->{'imap'} = $imap;

        unless ( $conf->{'emailboxes'} ) {
            $conf->{'emailboxes'} = [];

            for my $i ( 0 .. $#{ $conf->{'mailboxes'} } ) {
                $conf->{'emailboxes'}->[$i]
                    = Encode::IMAPUTF7::encode( 'IMAP-UTF-7',
                    $conf->{'mailboxes'}->[$i] );
            }
        }
        $conf->{'opt'}->{'timeout'} = $opt->{'Interval'}
            unless defined $conf->{'opt'}->{'timeout'};
        $conf->{'opt'}->{'use_select_cache'} = 0
            unless defined $conf->{'opt'}->{'use_select_cache'};
    }
    return $error;
}

# ------------------------------------------------------------------------------
sub _check_one_imap {
    my ($opt) = @_;

    my $imap = $opt->{'imap'};
    my $error;

    $opt->{'new'} = 0;
    say $opt->{'name'} . q{:} if $DEBUG;

    for ( 0 .. $#{ $opt->{'mailboxes'} } ) {
        my ( $unseen, $recent, $msgs ) = $opt->{'imap'}->status($_);
        $unseen ||= 0;
        $recent ||= 0;
        $msgs   ||= 0;
        say " $opt->{'mailboxes'}->[$_]: $unseen, $recent, $msgs" if $DEBUG;
        $opt->{'new'} += $unseen;
    }

    if ($error) {
        $error =~ s/^\s+|\s+$//gs;
        say $error if $DEBUG;
        $opt->{'new'} = 0;
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
