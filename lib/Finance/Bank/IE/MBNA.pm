=head1 NAME

Finance::Bank::IE::MBNA - Finance::Bank interface for MBNA (Ireland)

=head1 DESCRIPTION

This module implements the Finance::Bank 'API' for MBNA (Ireland)'s online
credit card service.

=over

=cut
package Finance::Bank::IE::MBNA;

use strict;
use warnings;

our $VERSION = "0.24";

use base qw( Finance::Bank::IE );

use HTML::TokeParser;
use HTML::Entities;
use POSIX;
use Carp;

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

=item * $self->login( [config]

Attempt to log in, using specified config or cached config. Returns undef on failure.

=cut
sub login {
    my ( $self, $confref ) = @_;

    $confref ||= $self->cached_config();

    my ( $user, $password ) = ( $confref->{user}, $confref->{password} );

    if ( !defined( $user ) or !defined( $password )) {
        $self->_dprintf( "login requires a username and password\n" );
        return;
    }

    $self->cached_config( $confref );

    my $res = $self->_agent()->get( 'https://www.bankcardservices.co.uk/' );
    $self->_save_page();

    if ( !$res->is_success()) {
        $self->_dprintf( "Unable to fetch initial page" );
        if ( $res->message ) {
            $self->_dprintf( " ($res->message)" );
        }
        $self->_dprintf( "\n" );
        return;
    }

    # without this, the redirect link text is unfindable.  thank
    # you... netscape?  doubleplus thankyou for using meta instead of
    # a redirect code
    my $c = $self->_agent()->content();
    $c =~ s@url=([^"].*)>@url=\"$1"@i;
    $self->_agent()->update_html( $c );

    if ( $self->_agent()->find_link( tag => "meta" )) {
        $self->_agent()->follow_link( tag => "meta" );
        $self->_save_page();
    }

    # log in
    if ( $self->_agent()->content() !~ /olb_login/ ) {
        $self->_dprintf( "Login Form not found\n" );
        return;
    }

    $self->_dprintf( "logging in\n" );
    $res = $self->_agent()->submit_form(
                                        form_name => 'olb_login',
                                        fields => {
                                                   userID => $user,
                                                  },
                                       );
    $self->_save_page();

  RETRY:
    if ( !$res->is_success ) {
        $self->_dprintf( "Failed to log in\n" );
        return;
    }

    $c = $self->_agent()->content();

    # August 2009: security "improved" by putting login on one page
    # and password on another. Noone else seems to need to do this.
    if ( $c =~ /siteKeyConfirmForm/si ) {
        $self->_dprintf( "site key confirm\n" );
        $res = $self->_agent()->submit_form(
                                            form_name => 'siteKeyConfirmForm',
                                            fields => {
                                                       password => $password,
                                                      },
                                           );
        $self->_save_page();
        if ( !$res->is_success ) {
            $self->_dprintf( "Failed to log in\n" );
            return;
        }

        $c = $self->_agent()->content();
    }

    # maybe you've chosen to hide unregistered accounts?
    if ( $self->_agent()->find_link( url => 'RegisteredAccountsScreen?show=true' )) {
        $self->_dprintf( "revealing inactive accounts\n" );
        $res = $self->_agent()->follow_link( url => 'RegisteredAccountsScreen?show=true' );
        $self->_save_page();

        if ( !$res->is_success ) {
            $self->_dprintf( "Failed to reveal inactive accounts\n" );
            return;
        }

        $c = $self->_agent()->content();
    }

    # Check that we got logged in
    if ( $c !~ /Account Snapshot/si ) {
        if ( $c =~ /The user name-password combination you entered is not valid/si ) {
            print STDERR "Params: " . join( ":", @_ ) . "\n";

            carp( "Incorrect username/password\n" );
            return undef;
        } elsif ( $c =~ /update your e-mail address/si ) {
            $self->_dprintf( "accepting email address\n" );
            # this assumes your email address is (a) set and (b) correct
            $res = $self->_agent()->submit_form();
            $self->_save_page();
            goto RETRY;
        } elsif ( $c !~ /AccountSnapshotScreen/si ) {
            # we failed for some reason
            $self->_dprintf( "Failed to log in for unknown reason.\n" );
            return;
        }
    }

    return $self->_agent();
}

=item * $self->check_balance()

Fetch all account balances from the account summary page. Returns an array of Finance::Bank::IE::MBNA::Account objects.

=cut

sub check_balance {
    my ( $self, $confref ) = @_;
    my @accounts;
    my @cards;

    $self->login( $confref ) or return;

    my $c = $self->_agent()->content;

    # assume you've got multiple accounts...
    @cards =
      $self->_agent()->find_all_links( url_regex => qr/AccountSnapshotScreen/ );

    if ( @cards ) {
        # uniquify it
        my %cards;
        for my $ca ( @cards ) {
            $cards{$ca->url_abs} = $ca;
        }
        @cards = ();

        for my $card ( values %cards ) {
            $self->_dprintf( "fetching card summary (" . $card->text . ")\n" );
            my $res = $self->_agent()->get( $card->url_abs());
            $self->_save_page();
            if ( $res->is_success()) {
                my $summary = parse_account_summary( $self, $self->_agent()->content );
                my ( $type, $account ) = $card->text =~
                  m@MBNA (.*?ard), account number ending ([0-9]+)@;
                $summary->{account_type} = $type;
                $summary->{account_no} = $account;
                push @accounts, $summary;
            } else {
                $self->_dprintf( "Failed to get card summary for " .
                                 $card->text . "\n" );
            }
        }
    } else {
        $self->_dprintf( "No cards found\n" );
    }

    @accounts;
}

=item * $self->account_details( account [,config] )

 Return transaction details from the specified account

=cut

sub account_details {
    my ( $self, $account, $confref ) = @_;

    $self->login( $confref );
    my $c = $self->_agent()->content;
    return unless $c;
    if ( $c !~ /Transaction\s+Date/i ) {
        my @cards =
          $self->_agent()->find_all_links( url_regex => qr /AccountSnapshotScreen/ );
        if ( @cards ) {
            my $found = 0;
            for my $ca ( @cards ) {
                if ( $ca->text =~ /\b$account\b/ ) {
                    $found = $ca;
                    last;
                }
            }
            if ( !$found ) {
                $self->_dprintf( "no such account $account\n" );
                return;
            }

            $self->_dprintf( "fetching card details (" . $found->text . ")\n" );
            my $res = $self->_agent()->get( $found->url_abs());
            $self->_save_page();
            if ( !$res->is_success()) {
                $self->_dprintf("failed to get detail page for $account\n" );
                return;
            }
        } else {
            $self->_dprintf("no cards found\n");
            return;
        }
    }

    # one way or another, we're on the right page now
    $c = $self->_agent()->content;

    my $parser = new HTML::TokeParser( \$c );

    my @activity;
    my @line;
    while ( my $tag = $parser->get_tag( "td", "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( @line ) {
                $line[MCC] ||= ""; # no longer provided in summary
                # clean up the data a bit
                $line[TXDATE] =~ s/\xa0//;         # nbsp, I guess
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

    if ( @activity ) {
        unshift  @activity,
          [ "Transaction Date", "Posting Date", "MCC", "Description", "Debit", "Credit" ];
    }

    return @activity;
}

=item * $self->parse_account_summary

Internal function to parse account summary pages.

=cut

sub parse_account_summary {
    my $self = shift;
    my $content = shift;
    my %detail;

    ( $detail{account_id} ) = $content =~ /acctID=([^"]+)"/s;

    $self->_dprintf( "parsing $detail{account_id}\n" );

    my $parser = new HTML::TokeParser( \$content );
    while ( my $t = $parser->get_tag( "div" )) {
        my $class = $t->[1]{class} || "";

        if ( $class =~ /\bcolumn1\b/ ) {
            my $title = $parser->get_trimmed_text( "/div" );
            $t = $parser->get_tag( "div" );
            my $text = $parser->get_trimmed_text( "/div" );

            $self->_dprintf( "title: $title, text: $text\n" );

            if ( $title =~ /pending transactions/i ) {
                $title = 'unposted';
                $text =~ s/[()]//g;
            } elsif ( $title =~ /minimum payment due/i ) {
                $title = 'min';
            } elsif ( $title =~ /payment to be received/i ) {
                $title = 'due';
            } elsif ( $title =~ /your outstanding balance/i ) {
                $title = 'balance';
                my $cr = $text =~ /\d+(CR)/;
                $text =~ s/[^0-9]+refresh balance//i;
                $text .= "CR" if $cr;
            } elsif ( $title =~ /available for cash/i ) {
                $title = 'space',
            } else {
                next;
            }

            $self->_dprintf( "=> title: $title, text: $text\n" );

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
            my ( $currency, $amount, $credit ) = $detail{$field} =~ m/^([^0-9]+)([0-9,.]+(CR)?)$/;
            $currency = 'EUR' if $currency eq '&euro;';
            $detail{currency} = $currency;
            $amount =~ s/,//g;
            if ( $credit && $credit =~ /CR/ ) {
                $amount =~ s/CR//;
                $amount = -$amount;
            }
            $detail{$field} = $amount;
        }

    }

    # minor fixups to match old behaviour. needlessly ugly.
    if ( $detail{due}) {
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
    }

    $detail{unposted} ||= 0;

    bless \%detail, "Finance::Bank::IE::MBNA::Account";

    \%detail;
}

=back

=cut

package Finance::Bank::IE::MBNA::Account;

no strict;

# I understand this now. That scares me.
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
