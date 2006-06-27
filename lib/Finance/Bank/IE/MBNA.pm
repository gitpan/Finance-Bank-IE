#!/usr/bin/perl -w
#
# Interface to MBNA's website (credit cards only, and only one credit
# card at that)
#
package Finance::Bank::IE::MBNA;

our $VERSION = "0.07";

use strict;
use WWW::Mechanize;
use HTML::TokeParser;
use HTML::Entities;
use Carp;

# package-local
my $agent;
my %cached_config;

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
    if ( $agent->content() !~ /loginForm/ ) {
        croak( "Login Form not found\n" );
    }

    $res = $agent->submit_form(
                               form_name => 'loginForm',
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

    # Check that we got logged in
    if ( $c !~ /Account Snapshot/si ) {
        if ( $c =~ /The user name-password combination you entered is not valid/si ) {
            print STDERR "Params: " . join( ":", @_ ) . "\n";

            carp( "Incorrect username/password\n" );
            return undef;
        } elsif ( $c =~ /update your e-mail address/si ){
            # this assumes your email address is (a) set and (b) correct
            $res = $agent->submit_form();
            goto RETRY;
        } elsif ( $c !~ /Please select one/ ) {
            # we failed for some reason
            open( DUMP, ">" . $ENV{HOME} . "/mbna.dump" );
            print DUMP $c;
            close( DUMP );
            croak( "Failed to log in for unknown reason, check ~/mbna.dump" );
        }
    }

    return $agent;
}

sub check_balance {
    my ( $self, $confref ) = @_;
    my @accounts;
    my @cards;

    # temporary
    if ( ref( $confref ) ne "HASH" ) {
        croak( "sorry, API change" );
    }

    $self->login( $confref ) or return;

    my $c = $agent->content;
    if ( $c =~ /Please select one/ ) {
        # woo, you've got multiple accounts...
        @cards =
          $agent->find_all_links( url_regex => qr/AccountSnapshotScreen/ );

        if ( @cards ) {
            # uniquify it
            my %cards;
            for my $ca ( @cards ) {
                $cards{$ca->url_abs} = $ca;
            }
            @cards = ();
#            $res = $agent->get( $card->url_abs());
#            goto RETRY;
            for my $card ( values %cards ) {
                my $res = $agent->get( $card->url_abs());
                if ( $res->is_success()) {
                    push @cards, $agent->content;
                }
            }
        }
    } else {
        push @cards, $c;
    }

    for my $c ( @cards ) {
        # The account number, ish
        my $account = get_cell_after( \$c, ".*card" );
        my $space = get_cell_after( \$c, "available for cash or purchases" );
        my $balance = get_cell_after( \$c, "outstanding balance", 4 );
        my $unposted = get_cell_after( \$c, "unposted transactions" );
        my $min = get_cell_after( \$c, "total minimum payment" );
        my $currency = get_cell_after( \$c, "^Amount", 0 );

        # clean out any euro signs
        $space =~ s/^.*?(\d+)/$1/;
        $balance =~ s/^.*?(\d+)/$1/;
        $unposted =~ s/^.*?(\d+)/$1/;
        $min =~ s/^.*?(\d+)/$1/;

        $currency =~ s/Amount \((.*)\)$/$1/;

        # currency may be returned as a HTML entity!
        $currency = decode_entities( $currency );
        # err.
        if ( $currency eq "&#8364;" or $currency eq "\x{20ac}" ) {
            $currency = "EUR";
        }

        $balance ||= "unavailable";
        $space ||= "unavailable";
        $unposted ||= "unavailable";
        $min ||= 0;

        # pass back what we found as an array of accounts.
        my $ac =bless {
                       account_no => $account,
                       currency => $currency,
                       balance => $balance,
                       space => $space,
                       unposted => $unposted,
                       min => $min,
                      }, "Finance::Bank::IE::MBNA::Account";
        push @accounts, $ac;
    }

    # go to the statements page:
    #https://www.bankcardservices.co.uk/NASApp/NetAccessXX/RecentStatementsScreen?acctID=...

    @accounts;
}

sub get_cell_after {
    my $c = shift;
    my $matchtext = shift;
    my $cells = shift;

    my $parser = new HTML::TokeParser( $c );

    $cells = 1 if !defined( $cells );

    while ( my $t = $parser->get_token() ) {
        if ( $t->[0] eq "T" ) {
            my $text = $t->[1];
            if ( $text =~ /$matchtext/is ) {
                if ( $cells == 0 ) {
                    return trim( $text );
                }

                # jump to the next table cell
                for my $c ( 1..$cells ) {
                    $t = $parser->get_token( "td" );
                }
                my $ret = $parser->get_trimmed_text( "/td" );
                $ret =~ s/&#8364;//gs;
                $ret =~ s/,//gs;
                return trim( $ret );
            }
        }
    }
}

sub trim {
    my $text = shift;
    $text =~ s/^\s+//;
    $text =~ s/\s$//;

    $text;
}

package Finance::Bank::IE::MBNA::Account;

no strict;

# I understand this now. That scares me.
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
