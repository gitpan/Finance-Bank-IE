#!/usr/bin/perl -w
#
# Interface to MBNA's website
#
package Finance::Bank::IE::MBNA;

our $VERSION = "0.13";

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
        } elsif ( $c !~ /my accounts/si ) {
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
            my $res = $agent->get( $card->url_abs());
            if ( $res->is_success()) {
                push @cards, $agent->content;
            }
        }
    }

    for my $c ( @cards ) {
        # The account number, ish
        my ( $type, $account ) = $c =~ /account details for your (.*?), account number.*?(\d+)/si;

        my $space = get_cell_after( \$c, "available for cash or purchases" );
        my $balance = get_cell_after( \$c, "outstanding balance", 4 );
        my $unposted = get_cell_after( \$c, "pending transactions" );
        my $min = get_cell_after( \$c, "total minimum payment" );
        my $currency = get_cell_after( \$c, "^Amount", 0 );

        # clean out any euro signs
        $space =~ s/^.*?(\d+)/$1/;
        $balance =~ s/^.*?(\d+)/$1/;

        if ( $balance =~ s/CR// ) {
            # lucky you, you're in credit, so we'll leave it as-is
        } else {
            $balance = -$balance;
        }

        if ( $unposted =~ s/^.*?(\d+)/$1/ ) {
            # your balance is not complete, but that's ok
        } else {
            # no unposted items, let's make sure it's not text
            $unposted = 0;
        }

        $min =~ s/^.*?(\d+)/$1/;

        $currency =~ s/Amount.*\((.*)\)$/$1/;

        # currency may be returned as a HTML entity!
        $currency = decode_entities( $currency );
        # err.
        if ( $currency eq "&#8364;" or $currency eq "\x{20ac}" or
            $currency eq "\x{e282}" ) {
            $currency = "EUR";
        }

        $min ||= 0;

        # go to the statements page since it would be nice to be able
        # to pull a range of transactions
        my ( $acct ) = $c =~ /acctID=\d+/s;
        my @statements;
        if ( defined( $acct )) { # and it should be
            my $res = $agent->get( "https://www.bankcardservices.co.uk/NASApp/NetAccessXX/RecentStatementsScreen?acctID=$acct" );
            if ( $res->is_success()) {
                my @st = $agent->find_all_links( url_regex => qr/StatementScreen/ );
                for my $s ( @st ) {
                    push @statements, [ $s->url_abs, $s->text ];
                }
            }
        }

        # pass back what we found as an array of accounts.
        my $ac =bless {
            account_id => $acct,
            account_type => $type,
            account_no => $account,
            currency => $currency,
            balance => $balance,
            space => $space,
            unposted => $unposted,
            min => $min,
        }, "Finance::Bank::IE::MBNA::Account";
        push @accounts, $ac;
    }

    @accounts;
}

sub account_details {
    my ( $self, $account, $confref ) = @_;

    $self->login( $confref );
    my $c = $agent->content;
    if ( $c =~ /Please select one/ ) {
        my @cards =
            $agent->find_all_links( url_regex => qr /AccountSnapshotScreen/ );
        if ( @cards ) {
            my $found = 0;
            for my $ca ( @cards ) {
                if ( $ca->text eq $account ) {
                    $found = $ca;
                    last;
                }
            }
            croak( "no such account $account" ) unless $found;

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
        next unless ( $tag->[1]{class}||"" ) =~ /^txn(Hi|Lo)$/;
        push @line, $parser->get_trimmed_text( "/td" );
    }

    return @activity;
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

    dumppage( ${$c} );

    confess( "Unable to find text matching $matchtext" );
}

sub trim {
    my $text = shift;
    $text =~ s/^\s+//;
    $text =~ s/\s$//;

    $text;
}

sub dumppage {
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
