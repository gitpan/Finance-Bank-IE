#!/usr/bin/perl
# -*-CPerl-*-
# Banking 365ish
#
package Finance::Bank::IE::BankOfIreland;

=head1 NAME

Finance::Bank::IE::BankOfIreland - Interface to Bank of Ireland online banking

=head1 SYNOPSIS

 use Finance::Bank::IE::BankOfIreland;

 # config
 my $conf = { user => '', pin => '', contact => '', dob => '' };

 # get balance from all accounts
 my @accounts = Finance::Bank::IE::BankOfIreland->check_balance( $conf );

 # get account transaction details
 my @details = Finance::Bank::IE::BankOfIreland->account_details( $acct );

 # list beneficiaries for an account
 my $bene = Finance::Bank::IE::BankOfIreland->list_beneficiaries( $acct );

 # transfer money to a beneficiary
 my $tx = Finance::Bank::IE::BankOfIreland->funds_transfer( $from, $to, $amt );

=head1 DESCRIPTION

Module to interact with BoI's 365 Online service.

=head1 FUNCTIONS

Note that all functions are set up to act as methods (i.e. they all need to be invoked using F:B:I:B->method()). All functions also take an optional configuration hash as a final parameter.

=over

=cut

use strict;
use warnings;

our $VERSION = "0.24";

use base qw( Finance::Bank::IE );

# headers for account summary page
use constant {
    BALANCE  => "Balance Information: Balance",
      ACCTTYPE => "Account Type",
        NICKNAME => "Nickname Information: Nickname",
          CURRENCY => "Currency",
            ACCTNUM  => "Account Number",
        };

# headers for transaction list page
use constant {
    DATE => "Date",
      DETAIL => "Details",
        DEBIT => "Debit",
          CREDIT => "Credit",
            DETBAL => "Balance Information: Balance",
        };

# headers for payments page
use constant {
    BENNAME => 'Beneficiary Name Information: Beneficiary Name',
      BENACCT => 'Account Number',
        BENNSC =>
          'National Sort Code (NSC) Information: National Sort Code (NSC)',
            BENREF => 'Reference Number Information: Reference Number',
              BENDESC =>
                'Beneficiary Description Information: Beneficiary Description',
                  BENSTATUS => 'Status Information: Status',
              };

my $BASEURL = "https://www1.365online.com/";

use HTML::TokeParser;
use Carp;
use Date::Parse;
use POSIX;
use File::Path;
use Data::Dumper;


=item login_dance( $config );

Logs in or refreshes the current session. The config parameter is a hash reference which is cached the first time it is used, so can be omitted thereafter. The contents of the hash are the login details for your 365 Online account:

=over

=item * user: your six-digit BoI user ID

=item * pin: your six-digit PIN

=item * contact: the last four digits of your contact number

=item * dob: your date of birth in DD/MM/YYYY format

=back

No validation is currently done on the format of the config items. The function returns true or false. Note that this function should rarely need to be directly used as it's invoked by the other functions as a first step.

=cut

sub login_dance {
    my $self = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();

    for my $required ( "user", "pin", "contact", "dob" ) {
        if ( !defined( $confref->{$required} )) {
            $self->_dprintf( "$required not specified\n" );
            return;
        }
    }

    $self->cached_config( $confref );

    my $res =
      $self->_agent()->get( $BASEURL . 'servlet/Dispatcher/onlinebanking.htm' );
    $self->_save_page();
    if ( $res->is_success ) {
        if ( $self->_agent()->content !~ /timeout.htm/si ) {
            $self->_dprintf( "Short-circuit: session still valid\n" );
            return 1;
        }
    }
    $self->_dprintf( "Session has timed out, redoing login\n" );

    # fetch ye login pageibus
    $res = $self->_agent()->get( $BASEURL . 'servlet/Dispatcher/login.htm' );
    $self->_save_page();

    if ( !$res->is_success ) {
        croak( "Failed to get login page." );
    }

    # helpfully, BoI removed the form name, so we're going to rely on
    # it being the only form on the page for now.
    $self->_agent()->field( "USER", $confref->{user} );
    my $form = $self->_agent()->current_form();
    my $field = $form->find_input( "Pass_Val_1" );
    if ( !defined( $field )) {
        croak( "unrecognised secret type" );
    }

    if ( $self->_agent()->content =~ /your date of birth/is ) {
        $self->_agent()->field( "Pass_Val_1", $confref->{dob} );
    } else {
        $self->_agent()->field( "Pass_Val_1", $confref->{contact} );
    }

    $res = $self->_agent()->submit_form( button => 'submit', 'x' => 139, 'y' => 16 );
    $self->_save_page();

    if ( !$res->is_success ) {
        croak( "Failed to submit login form" );
    } else {
        $self->_dprintf( $res->request->as_string );
    }

    $self->_set_pin_fields( $confref );
    $res = $self->_agent()->submit_form();
    $self->_save_page();

    if ( !$res->is_success ) {
        croak( "Failed to submit login form" );
    }

    my $page = $res->content;

    # We need to check for the phishing page, because otherwise we're
    # not going to get any further info. Let's follow the Ha_Det link
    # first.
    #
    # There's also a T&C page which I'm not going to cater for
    # specifically because it's a T&C page. You want it, you read it.
    my ( $loc ) = $page =~ /Ha_Det.*location.href="\/?(.*?)"/s;
    if ( $loc ) {
        $self->_dprintf( "being redirected to $loc...\n" );
        $res = $self->_agent()->get( $loc =~ /^http/ ? $loc : $BASEURL . $loc );
        $self->_save_page();
        if ( !$res->is_success ) {
            croak( "Failed to get Ha_Det page: $loc" );
        }
    } else {
        if ( $page =~ /details are incorrect/si ) {
            croak( "Your login details are incorrect!" );
        }
        croak( "Login failed: we didn't get the Ha_Det page" );
    }

    # Now check if it pulls in the phishing page.
    $self->_dprintf( "phishing page check: " );
    if ( $self->_agent()->find_link( url_regex => qr/phishing_notification/ )) {
        $self->_dprintf( "found\n" );
        $res =
          $self->_agent()->follow_link( url_regex => qr/phishing_notification/ );
        $self->_save_page();

        if ( !$res->is_success ) {
            croak( "Failed to get phishing page" );
        }
        # The page has a single form on it which we must submit
        $res = $self->_agent()->submit_form();
        if ( !$res->is_success ) {
            $self->_save_page();
            croak( "Failed to submit phishing page" );
        }
    } else {
        $self->_dprintf( "none\n" );
    }

    $self->_save_page();

    return 1;
}

=item $self->check_balance()

Fetch all account balances from the account summary page. Returns an array of Finance::Bank::IE::BankOfIreland::Account objects.

=cut

sub check_balance {
    my $self = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();
    $self->login_dance( $confref );

    # Banking frameset:
    # main frame - onlinebanking.html
    #     - subframes marbar3_pb.htm, bank.htm
    #     - bank.htm subframes navbar.htm?status=0 / accsum.htm
    $self->_dprintf( "Getting balance page\n" );
    my $res =
      $self->_agent()->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );
    $self->_save_page();

    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    my $summary = $res->content;
    my $parser = new HTML::TokeParser( \$summary );

    my ( @accounts, %account, @headings );
    my ( $getheadings, $col ) = ( 1, 0 );

    while ( my $tag = $parser->get_tag( "div" )) {
        last if ($tag->[1]{class}||"") eq "account_tables";
    }
    while ( my $tag = $parser->get_tag( "td", "th",  "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( $getheadings ) {
                carp( "Did not find expected headings" ) unless
                  grep BALANCE, @headings and
                    grep ACCTTYPE, @headings and
                      grep NICKNAME, @headings and
                        grep CURRENCY, @headings and
                          grep ACCTNUM, @headings;
            }
            $getheadings = 0;
            $col = 0;

            if ( %account and $account{+ACCTTYPE} ne ACCTTYPE ) {
                $account{+BALANCE} = undef if
                  $account{+BALANCE} eq "Unavailable";
                push @accounts,
                  bless {
                         type => delete $account{+ACCTTYPE},
                         nick => delete $account{+NICKNAME},
                         account_no => delete $account{+ACCTNUM},
                         currency => delete $account{+CURRENCY},
                         balance => delete $account{+BALANCE},
                        }, "Finance::Bank::IE::BankOfIreland::Account";
            }
            next;
        }

        my $text = $parser->get_trimmed_text( "/" . $tag->[0] );
        $text =~ s/\xa0//;      # nbsp, I guess

        if ( $getheadings ) {
            push @headings, $text;
            next;
        }

        $account{$headings[$col]} = $text if $headings[$col];
        $col++;
    }

    if ( !@accounts ) {
        $self->_dprintf( "No accounts found\n" );
    }

    return @accounts;
}

=item *$self->account_details( account [,config] )

 Return transaction details from the specified account

=cut
sub account_details {
    my $self = shift;
    my $account = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();
    $self->login_dance( $confref );

    # Banking frameset:
    # main frame - onlinebanking.html
    #     - subframes marbar3_pb.htm, bank.htm
    #     - bank.htm subframes navbar.htm?status=0 / accsum.htm
    my $res =
      $self->_agent()->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );
    $self->_save_page();

    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    if ( my $l = $self->_agent()->find_link( text => $account )) {
        $self->_agent()->follow_link( text => $account )
          or croak( "Couldn't follow link to account number $account" );
        $self->_save_page();
    } else {
        croak "Couldn't find a link for $account";
    }

    # the returned file is a frameset
    my $detail = $self->_agent()->content;

    if ( $detail =~ /txlist.htm/s ) {
        $self->_agent()->follow_link( url_regex => qr/txlist.htm/ ) or
          croak( "couldn't follow link to transactions" );
        $self->_save_page();
    } else {
        croak( "frameset not found" );
    }

    # now fetch as many pages as it's willing to give us
    my @activity;
    my @header;
    my $page = 1;
    while ( 1 ) {
        $detail = $self->_agent()->content;

        my ( $hdr, $act ) = $self->_parse_details( \$detail );
        if ( !$act or !$hdr or !@{$act} or !@{$hdr}) {
            last;
        }

        push @activity, @{$act};
        if ( !@header ) {
            @header = @$hdr;
        }

        if ( $detail =~ /cont_but_next/i ) {
            $self->_agent()->follow_link( url_regex => qr/txlist.htm/ )
              or croak( "next link failed" );
            $self->_save_page();
        } else {
            unshift @activity, \@header;
            last;
        }
    }

    return @activity;
}

=item * $self->_parse_details( $content );

 Parse the transaction listing page (C<content>) into an array ref

=cut
sub _parse_details {
    my $self = shift;
    my $content = shift;
    my $parser = new HTML::TokeParser( $content );

    my ( @lines, %line, @headings );
    my ( $getheadings, $col ) = ( 1, 0 );

    while ( my $tag = $parser->get_tag( "td", "th", "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( $getheadings ) {
                # sanity check
                carp( "Did not find expected headings" ) unless
                  grep DETAIL, @headings and
                    grep DATE, @headings and
                      grep CREDIT, @headings and
                        grep DEBIT, @headings and
                          grep DETBAL, @headings;
            }
            $getheadings = 0;
            $col = 0;

            if ( $line{+DETAIL}||"" ) {
                # fixups
                $line{+DATE} ||= $lines[-1]->[0] if @lines;
                $line{+DATE} ||= ""; # triggers failure
                $line{+DEBIT} ||= "0.00";
                $line{+CREDIT} ||= "0.00";
                $line{+DETBAL} ||= ( @lines ? $lines[-1]->[-1] : 0 ) -
                  $line{+CREDIT} + $line{+DEBIT};

                # now convert the date to unix time
                my ( $d, $m, $y ) = $line{+DATE} =~ /(\d+).(\w+).(\d+)/;
                my $t = str2time( "$d/$m/$y" ) if defined( $d ) and
                  defined( $m ) and defined( $y );
                if ( defined( $t )) {
                    $line{+DATE} = strftime( "%d-%b-%Y", localtime( $t ));
                } else {
                    carp( "Date format changed to " . $line{+DATE} );
                }
                push @lines,
                  [
                   delete $line{+DATE},
                   delete $line{+DETAIL},
                   delete $line{+DEBIT},
                   delete $line{+CREDIT},
                   delete $line{+DETBAL},
                  ];
            } else {
                # XXX should do something useful here to verify that this
                # really is a blank line
            }
            next;
        }

        my $text = $parser->get_trimmed_text( "/" . $tag->[0] );
        $text =~ s/\xa0/ /g;

        if ( $getheadings ) {
            push @headings, $text;
            next;
        }

        $line{$headings[$col]} = $text if $headings[$col];
        $col++;
    }

    # clean up headings
    @headings = grep !/^\s*$/, @headings;

    return \@headings, \@lines;
}

=item * $self->list_beneficiaries( account )

 List beneficiaries of C<account>

=cut
sub list_beneficiaries {
    my $self = shift;
    my $account_from = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();
    $self->login_dance( $confref );

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account" ) {
        $account_from = $account_from->{nick};
    }

    my $res =
      $self->_agent()->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );
    $self->_save_page();
    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    $self->_agent()->follow_link( text => $account_from )
      or croak( "Couldn't follow link to account $account_from" );
    $self->_save_page();

    $self->_agent()->follow_link( url_regex => qr/^navbar.htm/ )
      or croak( "Couldn't load navbar" );
    $self->_save_page();

    $self->_agent()->follow_link( text => "Money Transfer" )
      or croak( "Couldn't load money transfer" );
    $self->_save_page();

    my $beneficiaries = $self->_parse_beneficiaries( $self->_agent()->content );

    $beneficiaries;
}

=item * $self->funds_transfer( from, to, amount [,config] )

 Transfer C<amount> from C<from> to C<to>, optionally using C<config> as the config data.

=cut

sub funds_transfer {
    my $self = shift;
    my $account_from = shift;
    my $account_to = shift;
    my $amount = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();
    $self->login_dance( $confref );

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account" ) {
        $account_from = $account_from->{nick};
    }

    if ( ref $account_to eq "Finance::Bank::IE::BankOfIreland::Account" ) {
        $account_to = $account_to->{nick};
    }

    my $beneficiaries = list_beneficiaries( $self, $account_from, $confref );

    my $acct;
    for my $bene ( @{$beneficiaries} ) {
        if ((( $bene->{account_no} ||'' ) eq $account_to ) or
            (( $bene->{nick} ||'' ) eq $account_to )) {
            croak "Ambiguous destination account $account_to"
              if $acct;
            $acct = $bene;
        }
    }

    if ( !defined( $acct )) {
        croak( "Unable to find $account_to in list of accounts" );
    }

    if ( $acct->{status} eq "Inactive" ) {
        croak( "Inactive beneficiary" );
    }

    $self->_agent()->submit_form(
                        fields => {
                                   rd_pay_cancel => $acct->{input},
                                   txt_pay_amount => $amount,
                                  },
                       ) or croak( "Form submit failed" );
    $self->_save_page();

    $self->_set_pin_fields( $confref );
    $self->_agent()->submit_form() or
      croak( "Payment confirm failed" );
    $self->_save_page();

    if ( $self->_agent()->content !~ /your request.*is confirmed/si ) {
        croak( "Payment failed" );
    }

    # return the 'receipt'
    return $self->_agent()->content;
}

=item * $self->activate_beneficiary( $acct, $bene, $code )

Activate the specified beneficiary using the provided activation code.

=cut

sub activate_beneficiary {
    my ( $self, $account_from, $account_to, $code, $confref ) = @_;

    $confref ||= $self->cached_config();

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account" ) {
        $account_from = $account_from->{nick};
    }

    # deref account_to as well
    if ( ref $account_to eq "Finance::Bank::IE::BankOfIreland::Account" ) {
        $account_to = $account_to->{nick};
    }

    my $beneficiaries = list_beneficiaries( $self, $account_from, $confref );

    my $acct;
    for my $bene ( @{$beneficiaries} ) {
        if ((( $bene->{account_no} ||'' ) eq $account_to ) or
            (( $bene->{nick} ||'' ) eq $account_to )) {
            croak "Ambiguous destination account $account_to"
              if $acct;
            $acct = $bene;
        }
    }

    if ( !defined( $acct )) {
        croak( "Unable to find $account_to in list of accounts" );
    }

    if ( $acct->{status} ne "Inactive" ) {
        croak( "Active beneficiary" );
    }

    # need to select the beneficiary, then click "Activate Beneficiary"
    # this produces a warning due to an unnamed button, so we'll fix that
    my $form = $self->_agent()->current_form();
    for my $input ( $form->inputs()) {
        if ( !defined( $input->{name} )) {
            $input->{name} = 'noname';
        }
    }
    $self->_agent()->submit_form(
                        fields => {
                                   rd_pay_cancel => $acct->{input},
                                  },
                        button => 'activatebenf',
                       );
    $self->_save_page();

    $self->_agent()->submit_form(
                        fields => {
                                   txtActivationCode => $code,
                                  }
                       );
    $self->_save_page();

    if ( $self->_agent()->content !~ /you have successfully activated the following beneficary/si ) {
        return 1;
    }

    return 0;
}

=item * $self->parse_beneficiaries( content ) 

  Parse the beneficiaries page (C<content>). Returns a bunch of accounts.

=cut
sub _parse_beneficiaries {
    my $self = shift;
    my $content = shift;

    my $parser = new HTML::TokeParser( \$content );

    my ( @lines, %line, @headings );
    my ( $getheadings, $col, $tag ) = ( 1, 0 );

    while ( $tag = $parser->get_tag( "table" )) {
        last if ( $tag->[1]{summary}||"" ) =~
          /details of your registered/i;
    }
    if (( $tag->[1]{summary}||"" ) !~ /details of your registered/i ) {
        croak( "can't find accounts table #2" );
    }

    while ( my $tag = $parser->get_tag( "td", "th", "/tr", "/table" )) {
        last if $tag->[0] eq "/table";
        if ( $tag->[0] eq "/tr" ) {
            if ( $getheadings ) {
                for my $heading ( +BENNAME, +BENACCT, +BENNSC, +BENREF,
                                  +BENDESC, +BENSTATUS ) {
                    my $h = quotemeta( $heading );
                    croak( "missing heading $heading" ) unless
                      grep /^$h$/, @headings;
                }
            }
            $getheadings = 0;
            $col = 0;

            push @lines,
              [
               delete $line{+BENNAME},
               delete $line{+BENACCT},
               delete $line{+BENNSC},
               delete $line{+BENREF},
               delete $line{+BENDESC},
               delete $line{+BENSTATUS},
              ];
            next;
        }

        my $text = $parser->get_trimmed_text( "/" . $tag->[0] );
        $text =~ s/\xa0/ /g;

        if ( $getheadings ) {
            push @headings, $text;
            next;
        }

        $line{$headings[$col]} = $text if $headings[$col];
        $col++;
    }

    # reset the parser and pull the inputs
    $parser = new HTML::TokeParser( \$content );

    while ( $tag = $parser->get_tag( "table" )) {
        last if ( $tag->[1]{summary}||"" ) =~
          /details of your registered/i;
    }

    my $line = 0;
    my $input;
    while ( my $tag = $parser->get_tag( "/tr", "input" )) {
        if ( $tag->[0] eq "/tr" ) {
            push @{$lines[$line]}, $input->[1]->{value}
              unless ($input->[1]->{value}||"")
                =~ /(activate|delete) a beneficiary/i;
            $input = undef;
            $line++;
        } else {
            $input = $tag;
        }
    }

    # now clean up the whole mess.
    my @benes;
    for my $bene ( @lines ) {
        # no input -> not valid. but this is sort of bogus, so check
        # for the obviously bad one, too.
        next unless
          defined( $bene->[-1] ) and $bene->[-1] !~ /^(pay_future|)$/;

        push @benes,
          bless {
                 type => 'Beneficiary',
                 nick => $bene->[0],
                 account_no => $bene->[1],
                 nsc => $bene->[2],
                 ref => $bene->[3],
                 desc => $bene->[4],
                 status => $bene->[5],
                 input => $bene->[6],
                }, "Finance::Bank::IE::BankOfIreland::Account";
    }

    \@benes;
}

=item * $self->_set_pin_fields( $config )

  Parse the last received page for PIN entry fields, and populate them with the PIN digits from C<$config>.

=cut
sub _set_pin_fields {
    my $self = shift;
    my $confref = shift;

    my $page = $self->_agent()->content;

    if ( $page !~ /PIN_Val_1/s ) {
        if ( $page =~ /Session Timeout/ ) {
            $self->_dprintf( "Apparently your session timed out\n" );
        }
        croak( "PIN entry failed: we didn't get the PIN page" );
    }

    # now for the PIN - we could probably stuff this into a function
    my ( @pin ) =
      $page =~ /please (select|enter) the\s*(\d)\w+, (\d)\w+ and (\d)\w+ digits/si;

    if ( @pin ) {
        shift @pin; # because the first one will be the select/enter match
    }

    if ( $#pin != 2 ) {
        croak( "can't figure out what PIN digits are required" );
    }

    my $form = $self->_agent()->current_form();
    for my $pd ( 1..3 ) {
        my $idx = $pin[$pd - 1];
        my $field = $form->find_input( "PIN_Val_" . $pd );
        if ( !defined( $field )) {
            croak( "failed to find PIN_Val_$pd" );
        }
        $field->readonly( 0 );
        $self->_agent()->field( "PIN_Val_" . $pd,
                                substr( $confref->{pin}, $idx - 1 , 1 ));
    }
}

=item * $scrubbed = $self->_scrub_page( $content )

 Scrub the supplied content for PII.

=cut
sub _scrub_page {
    my ( $self, $content ) = @_;

    # fairly generic - really need to have something better here!
    $content =~ s/####[0-9]{4}/####9999/g;
    return $content;
}

=back

=cut

package Finance::Bank::IE::BankOfIreland::Account;

# magic (pulled directly from other code, which I now understand)
no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
