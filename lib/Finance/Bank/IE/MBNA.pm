#!/usr/bin/perl -w
#
# Interface to MBNA's website
#
package Finance::Bank::IE::MBNA;

our $VERSION = "0.24";

use strict;
use WWW::Mechanize;
use HTML::TokeParser;
use HTML::Entities;
use POSIX;
use Carp;

# package-local
my $agent;
my %cached_config;

# fields in detail listing
# Dear MBNA, your HTML is awful. empty <td> tags are the devil's work.
use constant {
    TXDATE => 1,
    POSTDATE => 3,
    MCC => 5,
    RATE => 7,
    DESC => 9,
    AMT => 11,
    CRED => 13,
};

# attempt to log in
# returns a logged-in WWW::Mechanize object, or undef
sub login {
    my ( $self, $confref ) = @_;

    $confref ||= \%cached_config;

    my ( $user, $password ) = ( $confref->{user}, $confref->{password} );

    if ( !defined( $user ) or !defined( $password )) {
        croak( "login requires a username and password" );
    }

    $cached_config{user} = $user;
    $cached_config{password} = $password;

    if ( !defined( $agent )) {
        $agent = WWW::Mechanize->new( env_proxy => 1, autocheck => 1 );
        $agent->env_proxy;

        $agent->quiet( 0 );
        $agent->agent_alias( 'Windows IE 6' );
    }

    my $res = $agent->get( 'https://www.bankcardservices.co.uk/' );

    # without this, the redirect link text is unfindable.  thank
    # you... netscape?  doubleplus thankyou for using meta instead of
    # a redirect code
    my $c = $agent->content();
    $c =~ s@url=([^"].*)>@url=\"$1"@i;
    $agent->update_html( $c );

    if ( $agent->find_link( tag => "meta" )) {
        $agent->follow_link( tag => "meta" );
    }

    # log in
    if ( $agent->content() !~ /olb_login/ ) {
        croak( "Login Form not found" );
    }

    print STDERR "# logging in\n" if $ENV{DEBUG};
    $res = $agent->submit_form(
        form_name => 'olb_login',
        fields => {
            userID => $user,
            password => $password,
        },
        );

  RETRY:
    if ( !defined( $res )) {
        croak( "Failed to log in" );
    }

    $c = $agent->content();

    # August 2009: security "improved" by putting login on one page
    # and password on another. Noone else seems to need to do this.
    if ( $c =~ /siteKeyConfirmForm/si ) {
        print STDERR "# site key confirm\n" if $ENV{DEBUG};
        $res = $agent->submit_form(
            form_name => 'siteKeyConfirmForm',
            fields => {
                password => $password,
            },
            );
        if ( !defined( $res )) {
            croak( "Failed to log in" );
        }

        $c = $agent->content();
    }

    # Check that we got logged in
    if ( $c !~ /Account Snapshot/si ) {
        if ( $c =~ /The user name-password combination you entered is not valid/si ) {
            print STDERR "Params: " . join( ":", @_ ) . "\n";

            carp( "Incorrect username/password\n" );
            return undef;
        } elsif ( $c =~ /update your e-mail address/si ){
            print STDERR "# accepting email address\n" if $ENV{DEBUG};
            # this assumes your email address is (a) set and (b) correct
            $res = $agent->submit_form();
            goto RETRY;
        } elsif ( $c !~ /AccountSnapshotScreen/si ) {
            # we failed for some reason
            dumppage( $c );
            croak( "Failed to log in for unknown reason, check ~/mbna.dump" );
        }
    }

    return $agent;
}

sub check_balance {
    my ( $self, $confref ) = @_;
    my @accounts;
    my @cards;

    $self->login( $confref ) or return;

    my $c = $agent->content;

    # assume you've got multiple accounts...
    @cards =
        $agent->find_all_links( url_regex => qr/AccountSnapshotScreen/ );

    if ( @cards ) {
        # uniquify it
        my %cards;
        for my $ca ( @cards ) {
            $cards{$ca->url_abs} = $ca;
        }
        @cards = ();

        for my $card ( values %cards ) {
            print STDERR "# fetching card summary (" . $card->text . ")\n"
                if $ENV{DEBUG};
            my $res = $agent->get( $card->url_abs());
            if ( $res->is_success()) {
                my $summary = parse_account_summary( $agent->content );
                my ( $type, $account ) = $card->text =~
                    m@MBNA (.*?ard), account number ending ([0-9]+)@;
                $summary->{account_type} = $type;
                $summary->{account_no} = $account;
                push @accounts, $summary;
            }
        }
    }

    @accounts;
}

sub account_details {
    my ( $self, $account, $confref ) = @_;

    $self->login( $confref );
    my $c = $agent->content;
    if ( $c !~ /Transaction\s+Date/i ) {
        my @cards =
            $agent->find_all_links( url_regex => qr /AccountSnapshotScreen/ );
        if ( @cards ) {
            my $found = 0;
            for my $ca ( @cards ) {
                if ( $ca->text =~ /\b$account\b/ ) {
                    $found = $ca;
                    last;
                }
            }
            croak( "no such account $account" ) unless $found;

            print STDERR "# fetching card details (" . $found->text . ")\n"
                if $ENV{DEBUG};
            my $res = $agent->get( $found->url_abs());
            if ( !$res->is_success()) {
                croak( "failed to get detail page for $account" );
            }
        }
    }

    # one way or another, we're on the right page now
    $c = $agent->content;

    my $parser = new HTML::TokeParser( \$c );

    my @activity;
    push @activity,
    [ "Transaction Date", "Posting Date", "MCC", "Description", "Debit", "Credit" ];
    my @line;
    while ( my $tag = $parser->get_tag( "td", "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( @line ) {
                $line[MCC] ||= ""; # no longer provided in summary
                # clean up the data a bit
                $line[TXDATE] =~ s/\xa0//; # nbsp, I guess
                $line[TXDATE] ||= $line[POSTDATE]; # just in case
                my ( $d, $m, $y ) = split( /\//, $line[TXDATE]);
                $line[TXDATE] = mktime( 0, 0, 0, $d, $m - 1, $y - 1900 );
                ( $d, $m, $y ) = split( /\//, $line[POSTDATE] );
                $line[POSTDATE] = mktime( 0, 0, 0, $d, $m - 1, $y - 1900 );
                $line[AMT] =~ s/\x{20ac}//;
                $line[MCC] =~ s/^\s+$//;

                push @activity,
                [
                 $line[TXDATE],
                 $line[POSTDATE],
                 $line[MCC],
                 $line[DESC],
                 $line[CRED] eq "CR" ? 0 : $line[AMT],
                 $line[CRED] eq "CR" ? $line[AMT] : 0,
                ];

                @line = ();
            }
            next;
        }
        my $class = $tag->[1]{class} || "";
        my $value = $parser->get_trimmed_text( "/td" );
        if ( $class =~ /\btxnColTransDate\b/ ) {
            $line[TXDATE] = $value;
        } elsif ( $class =~ /\btxnColPostDate\b/ ) {
            $line[POSTDATE] = $value;
        } elsif ( $class =~ /\btxnColDescr\b/ ) {
            $line[DESC] = $value;
        } elsif ( $class =~ /\btxnColAmount\b/ ) {
            $line[AMT] = $value;
        } elsif ( $class =~ /\btxnColCR\b/ ) {
            $line[CRED] = $value;
        }
    }

    return @activity;
}

sub parse_account_summary {
    my $content = shift;

    my %detail;

    ( $detail{account_id} ) = $content =~ /acctID=([^"]+)"/s;

    my $parser = new HTML::TokeParser( \$content );
    while( my $t = $parser->get_tag( "div" )) {
        my $class = $t->[1]{class} || "";

        if ( $class =~ /\bcolumn1\b/ ) {
            my $title = $parser->get_trimmed_text( "/div" );
            $t = $parser->get_tag( "div" );
            my $text = $parser->get_trimmed_text( "/div" );

            if ( $title =~ /pending transactions/i ) {
                $title = 'unposted';
                $text =~ s/[()]//g;
            } elsif ( $title =~ /minimum payment due/i ) {
                $title = 'min';
            } elsif ( $title =~ /payment to be received/i ) {
                $title = 'due';
            } elsif ( $title =~ /current balance/i ) {
                $title = 'balance';
                $text =~ s/[^0-9]+refresh balance//i;
            } elsif ( $title =~ /available for cash/i ) {
                $title = 'space',
            } else {
                next;
            }

            $detail{$title} = $text;
        }
    }

    # clean up
    for my $field ( keys %detail ) {
        # we can hack at the unicode, but converting to HTML entities
        # makes this code more obvious in terms of what's being
        # modified.
        $detail{$field} = encode_entities( $detail{$field} );
        $detail{$field} =~ s/&nbsp;/ /g;
        if ( grep { $_ eq $field } qw( min space balance unposted )) {
            my ( $currency, $amount ) = $detail{$field} =~ m/^([^0-9]+)([0-9,.]+)$/;
            $currency = 'EUR' if $currency eq '&euro;';
            $detail{currency} = $currency;
            $amount =~ s/,//g;
            $detail{$field} = $amount;
        }

    }

    # minor fixups to match old behaviour. needlessly ugly.
    my ( $day, $mon, $year ) = split( / /, $detail{due} );
    $mon = 1 if $mon eq 'Jan';
    $mon = 2 if $mon eq 'Feb';
    $mon = 3 if $mon eq 'Mar';
    $mon = 4 if $mon eq 'Apr';
    $mon = 5 if $mon eq 'May';
    $mon = 6 if $mon eq 'Jun';
    $mon = 7 if $mon eq 'Jul';
    $mon = 8 if $mon eq 'Aug';
    $mon = 9 if $mon eq 'Sep';
    $mon = 10 if $mon eq 'Oct';
    $mon = 11 if $mon eq 'Nov';
    $mon = 12 if $mon eq 'Dec';
    $detail{min} = $detail{min} . " due by $day/$mon/$year";

    # untested as I don't have a card in credit right now :)
    if ( !( $detail{balance} =~ s/CR// )) {
        $detail{balance} = -$detail{balance};
    }
    $detail{unposted} ||= 0;

    bless \%detail, "Finance::Bank::IE::MBNA::Account";

    \%detail;
}

sub dumppage {
    # avoid nasty surprises
    if ( !$ENV{DEBUG} ) {
        return;
    }
    my $c = shift;
    if ( open( DUMP, ">" . $ENV{HOME} . "/mbna.dump" )) {
        print DUMP $c;
        close( DUMP );
    } else {
        print STDERR "unable to create dumpfile: $!";
    }
}

package Finance::Bank::IE::MBNA::Account;

no strict;

# I understand this now. That scares me.
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
