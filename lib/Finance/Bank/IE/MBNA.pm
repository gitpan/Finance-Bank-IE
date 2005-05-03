#!/usr/bin/perl -w
#
# Interface to MBNA's website (credit cards only, and only one credit
# card at that)
#
package Finance::Bank::IE::MBNA;

our $VERSION = "0.03";

use strict;
use WWW::Mechanize;
use HTML::TokeParser;
use HTML::Entities;
use Carp;

sub check_balance {
    my @accounts;
    my ( $user, $password ) = @_;
    my %config;
    my @cards;

    if ( !defined( $user ) or !defined( $password )) {
        croak( "check_balance requires a username and password" );
    }

    my $agent = WWW::Mechanize->new( env_proxy => 1, autocheck => 1 );
    $agent->env_proxy;

    $agent->quiet( 0 );
    $agent->agent_alias( 'Windows IE 6' );

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

            carp( "Incorrect login/password\n" );
            return undef;
        } elsif ( $c =~ /update your e-mail address/si ){
            $res = $agent->submit_form();
            goto RETRY;
        } elsif ( $c =~ /Please select one/ ) {
            # woo, you've got multiple accounts...
            @cards =
              $agent->find_all_links( url_regex => qr/AccountSnapshotScreen/ );

            if ( @cards ) {
                # uniquify it
                my %cards;
                for my $ca ( @cards ) {
                    $cards{$ca->url_abs} = $ca;
                }
                @cards = values %cards;
                my $card = shift @cards;
                $res = $agent->get( $card->url_abs());
                goto RETRY;
            }
        }

        # otherwise we failed for some other reason
        open( DUMP, ">" . $ENV{HOME} . "/mbna.dump" );
        print DUMP $c;
        close( DUMP );
        croak( "Failed to log in for unknown reason, check ~/mbna.dump" );
    }

    # The account number, ish
    my $account = get_cell_after( \$c, ".*card" );
    my $space = get_cell_after( \$c, "available for cash or purchases" );
    my $balance = get_cell_after( \$c, "outstanding balance", 4 );
    my $unposted = get_cell_after( \$c, "unposted transactions" );
    my $min = get_cell_after( \$c, "total minimum payment" );
    my $currency = get_cell_after( \$c, "^Amount", 0 );

    $currency =~ s/Amount \((.*)\)$/$1/;

    # currency will be returned as a HTML entity!
    $currency = decode_entities( $currency );
    # err.
    if ( $currency eq "&#8364;" ) {
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

    # get more cards. going all the way back to RETRY is a little
    # excessive, but it'll do.
    if ( @cards ) {
        my $card = shift @cards;
        $res = $agent->get( $card->url_abs());
        goto RETRY;
    }

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
