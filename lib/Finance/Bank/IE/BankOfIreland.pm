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

our $VERSION = "0.21";

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

use WWW::Mechanize;
use HTML::TokeParser;
use Carp;
use Date::Parse;
use POSIX;
use File::Path;
use Data::Dumper;

# package-local variable
my $agent;
my $lastop = 0;
my %cached_config;

=item login_dance( $config );

Logs in or refreshes the current session. The config parameter is a hash reference which is cached the first time it is used, so can be omitted thereafter. The contents of the hash are the login details for your 365 Online account:

=over

=item * user: your six-digit BoI user ID

=item * pin: your six-digit PIN

=item * contact: the last four digits of your contact number

=item * dob: your date of birth in DD/MM/YYYY format

=back

No validation is currently done on the format of the config items. The function returns true or false. Error reporting is currently via croak or carp. There are some extra config options controlling debug output. Note that this function should rarely need to be directly used as it's invoked by the other functions as a first step.

=cut

sub login_dance {
    my $self = shift;
    my $confref = shift;

    $confref ||= \%cached_config;

    # try to create a debug directory if we need one
    if ( $confref->{debugdir}) {
        eval {
            mkpath( [ $confref->{debugdir} ], 0, 0700 );
        };
        if ( $@ ) {
            warn( "failed to create " . $confref->{debugdir} . ": $@" );
            delete $confref->{debugdir};
        }
    }

    my $croak = ( $confref->{croak} || 1 );

    for my $required ( "user", "pin", "contact", "dob" ) {
        if ( !defined( $confref->{$required} )) {
            if ( $croak ) {
                croak( "$required not specified" )
            } else {
                carp( "$required not specified" );
                return;
            }
        }
    }

    for my $k ( keys %{$confref} ) {
        $cached_config{$k} = $confref->{$k};
    }

    if ( !defined( $agent )) {
        $agent = WWW::Mechanize->new( env_proxy => 1,
                                      autocheck => 1,
                                      keep_alive => 10,
                                    );
        $agent->quiet( 0 );

        # most of this is an attempt to work with BoI's updated
        # website; eventually I gave up and fell back to using the
        # legacy website they provided for Safari.
        $agent->agent( 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.0.12) Gecko/20071126 Fedora/1.5.0.12-7.fc6 Firefox/1.5.0.12' );
        my $jar = $agent->cookie_jar();
        $jar->{hide_cookie2} = 1;
        $agent->add_header( 'Accept' => 'text/xml,application/xml,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,image/png,*/*;q=0.5' );
        $agent->add_header( 'Accept-Language' => 'en-US,en;q=0.5' );
        $agent->add_header( 'Accept-Charset' => 'ISO-8859-1,utf-8;q=0.7,*;q=0.7' );
        $agent->add_header( 'Accept-Encoding' => 'gzip,deflate' );
    } else {
        # simple check to see if the login is live
        if ( time - $lastop < 60 ) {
            $lastop = time;
            return 1;
        }
        my $res =
          $agent->get( $BASEURL . 'servlet/Dispatcher/onlinebanking.htm' );
        if ( $res->is_success ) {
            $lastop = time;
            print STDERR "Short-circuit: session still valid\n"
              if $confref->{debug};
            return 1;
        }
        print STDERR "Session has timed out, redoing login\n"
          if $confref->{debug};
    }

    # fetch ye login pageibus
    my $res = $agent->get( $BASEURL . 'servlet/Dispatcher/login.htm' );
    $agent->save_content( $confref->{debugdir} . '/login.htm' )
      if $confref->{debugdir};

    if ( !$res->is_success ) {
        croak( "Failed to get login page" );
    } else {
    }

    # helpfully, BoI removed the form name, so we're going to rely on
    # it being the only form on the page for now.
    $agent->field( "USER", $confref->{user} );
    my $form = $agent->current_form();
    my $field = $form->find_input( "Pass_Val_1" );
    if ( !defined( $field )) {
        croak( "unrecognised secret type" );
    }

    if ( $agent->content =~ /your date of birth/is ) {
        $agent->field( "Pass_Val_1", $confref->{dob} );
    } else {
        $agent->field( "Pass_Val_1", $confref->{contact} );
    }

    $res = $agent->submit_form( button => 'submit', 'x' => 139, 'y' => 16 );

    $agent->save_content( $confref->{debugdir} . '/login_submit.htm' )
      if $confref->{debugdir};

    if ( !$res->is_success ) {
        croak( "Failed to submit login form" );
    } else {
        print STDERR $res->request->as_string if $confref->{debug};
    }

    _set_pin_fields( $agent, $confref );
    $res = $agent->submit_form();

    if ( !$res->is_success ) {
        croak( "Failed to submit login form" );
    }

    my $page = $res->content;

    if ( $page !~ /Ha_Det/ ) {
        if ( $page =~ /authentication details are incorrect/si ) {
            croak( "Your login details are incorrect!" );
        }
        $agent->save_content( $confref->{debugdir} . "/login-failed.html" )
          if $confref->{debug};
        croak( "Login failed: we didn't get the Ha_Det page" );
    }

    # We need to check for the phishing page, because otherwise we're
    # not going to get any further info. Let's follow the Ha_Det link
    # first.
    #
    # There's also a T&C page which I'm not going to cater for
    # specifically because it's a T&C page. You want it, you read it.
    my ( $loc ) = $page =~ /Ha_Det.*location.href="\/?(.*?)"/s;
    $agent->save_content( $confref->{debugdir} . '/pin_submit.htm' )
      if $confref->{debugdir};
    print STDERR "being redirected to $loc...\n" if defined( $loc ) and
      $confref->{debug};
    $res = $agent->get( $loc =~ /^http/ ? $loc : $BASEURL . $loc );
    if ( !$res->is_success ) {
        croak( "Failed to get Ha_Det page: $loc" );
    }

    # Now check if it pulls in the phishing page.
    print STDERR "phishing page check: " if $confref->{debug};
    if ( $agent->find_link( url_regex => qr/phishing_notification.html/ )) {
        print STDERR "found\n" if $confref->{debug};
        $res =
          $agent->follow_link( url_regex => qr/phishing_notification.html/ );
        $agent->save_content( $confref->{debugdir} . '/phishing.htm' )
          if $confref->{debugdir};

        if ( !$res->is_success ) {
            croak( "Failed to get phishing page" );
        }
        # The page has a single form on it which we must submit
        $res = $agent->submit_form();
        if ( !$res->is_success ) {
            croak( "Failed to submit phishing page" );
        }
    } else {
        print STDERR "none\n" if $confref->{debug};
    }

    $agent->save_content( $confref->{debugdir} . '/post_login.htm' )
      if $confref->{debugdir};

    $lastop = time;

    return 1;
}

=item check_balance()

Fetch all account balances from the account summary page. Returns an array of Finance::Bank::IE::BankOfIreland::Account objects.

=cut

sub check_balance {
    my $self = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    $self->login_dance( $confref ) or return;

    # Banking frameset:
    # main frame - onlinebanking.html
    #     - subframes marbar3_pb.htm, bank.htm
    #     - bank.htm subframes navbar.htm?status=0 / accsum.htm
    print STDERR "Getting balance page\n" if $confref->{debug};
    my $res =
      $agent->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );

    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    $agent->save_content( $confref->{debugdir} . '/accsum.htm' )
      if $confref->{debugdir};

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
        print STDERR "No accounts found\n" if $confref->{debug};
        $agent->save_content( $confref->{debugdir} . '/noaccounts.html' )
          if $confref->{debugdir};
    }

    return @accounts;
}

sub account_details {
    my $self = shift;
    my $account = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    login_dance( $confref ) or return;

    # Banking frameset:
    # main frame - onlinebanking.html
    #     - subframes marbar3_pb.htm, bank.htm
    #     - bank.htm subframes navbar.htm?status=0 / accsum.htm
    my $res =
      $agent->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );

    $agent->save_content( $confref->{debugdir} . '/accsum.htm' )
      if $confref->{debugdir};

    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    if ( my $l = $agent->find_link( text => $account )) {
        $agent->follow_link( text => $account )
          or croak( "Couldn't follow link to account number $account" );
    } else {
        croak "Couldn't find a link for $account";
    }

    # the returned file is a frameset
    my $detail = $agent->content;

    if ( $detail =~ /txlist.htm/s ) {
        $agent->follow_link( url_regex => qr/txlist.htm/ ) or
          croak( "couldn't follow link to transactions" );
    } else {
        croak( "frameset not found" );
    }

    $agent->save_content( $confref->{debugdir} . '/txlist1.htm' )
      if $confref->{debugdir};

    # now fetch as many pages as it's willing to give us
    my @activity;
    my @header;
    my $page = 1;
    while ( 1 ) {
        $detail = $agent->content;

        my ( $hdr, $act ) = $self->_parse_details( \$detail );
        if ( !$act or !$hdr or !@{$act} or !@{$hdr}) {
            last;
        }

        push @activity, @{$act};
        if ( !@header ) {
            @header = @$hdr;
        }

        if ( $detail =~ /cont_but_next/i ) {
            $agent->follow_link( url_regex => qr/txlist.htm/ )
              or croak( "next link failed" );
            $page++;
            $agent->save_content( $confref->{debugdir} . "/txlist$page.htm" )
              if $confref->{debugdir};
        } else {
            unshift @activity, \@header;
            last;
        }
    }

    return @activity;
}

#
# Parse the transaction listing page into an array ref
#
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

sub list_beneficiaries {
    my $self = shift;
    my $account_from = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    login_dance( $confref ) or return;

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account"
         and defined( $account_from->{nick} )) {
        $account_from = $account_from->{nick};
    }

    my $res =
      $agent->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );
    if ( !$res->is_success ) {
        croak( "Failed to get account summary page" );
    }

    $agent->save_content( $confref->{debugdir} . "/accsum.htm" )
      if $confref->{debugdir};

    $agent->follow_link( text => $account_from )
      or croak( "Couldn't follow link to account $account_from" );

    $agent->save_content( $confref->{debugdir} . "/$account_from.htm" )
      if $confref->{debugdir};

    $agent->follow_link( url_regex => qr/^navbar.htm/ )
      or croak( "Couldn't load navbar" );

    $agent->save_content( $confref->{debugdir} . "/$account_from.navbar.htm" )
      if $confref->{debugdir};

    $agent->follow_link( text => "Money Transfer" )
      or croak( "Couldn't load money transfer" );

    $agent->save_content( $confref->{debugdir} .
                          "/$account_from.moneytransfer.htm" )
      if $confref->{debugdir};

    my $beneficiaries = $self->_parse_beneficiaries( $agent->content );

    $beneficiaries;
}

sub funds_transfer {
    my $self = shift;
    my $account_from = shift;
    my $account_to = shift;
    my $amount = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    login_dance( $confref ) or return;

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account"
         and defined( $account_from->{nick} )) {
        $account_from = $account_from->{nick};
    }

    if ( ref $account_to eq "Finance::Bank::IE::BankOfIreland::Account" and
         defined( $account_to->{nick} )) {
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

    $agent->submit_form(
                        fields => {
                                   rd_pay_cancel => $acct->{input},
                                   txt_pay_amount => $amount,
                                  },
                       ) or croak( "Form submit failed" );

    $agent->save_content( $confref->{debugdir} .
                          "/$account_from.moneytransfer." . $acct->{nick}
                          . ".htm" ) if $confref->{debugdir};

    _set_pin_fields( $agent, $confref );
    $agent->submit_form() or
      croak( "Payment confirm failed" );

    if ( $agent->content !~ /your request.*is confirmed/si ) {
        croak( "Payment failed" );
        $agent->save_content( $confref->{debugdir} .
                              "/$account_from.moneytransfer_failed.htm" )
          if $confref->{debugdir};
    }

    $agent->save_content( $confref->{debugdir} .
                          "/$account_from.moneytransfer_confirmed.htm" )
      if $confref->{debugdir};

    # return the 'receipt'
    return $agent->content;
}

=item activate_beneficiary( $acct, $bene, $code )

Activate the specified beneficiary using the provided activation code.

=cut

sub activate_beneficiary {
    my ( $self, $account_from, $account_to, $code, $confref ) = @_;

    $confref ||= \%cached_config;

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::BankOfIreland::Account"
         and defined( $account_from->{nick} )) {
        $account_from = $account_from->{nick};
    }

    # deref account_to as well
    if ( ref $account_to eq "Finance::Bank::IE::BankOfIreland::Account" and
         defined( $account_to->{nick} )) {
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
    $agent->submit_form(
                        fields => {
                                   rd_pay_cancel => $acct->{input},
                                  },
                        button => 'activatebenf',
                       );

    # WTF?
    $confref->{debugdir} = "/Users/waider/src/perl/Banking/data";

    $agent->save_content( $confref->{debugdir} .
                          "/$account_from.activate." . $acct->{nick}
                          . ".htm" ) if $confref->{debugdir};

    $agent->submit_form(
                        fields => {
                                   txtActivationCode => $code,
                                  }
                       );

    if ( $agent->content !~ /you have successfully activted the following beneficary/si ) {
        $agent->save_content( $confref->{debugdir} .
                              "/$account_from.activate_succeeded." . $acct->{nick}
                              . ".htm" ) if $confref->{debugdir};
        return 1;
    }

    $agent->save_content( $confref->{debugdir} .
                          "/$account_from.activate_failed." . $acct->{nick}
                          . ".htm" ) if $confref->{debugdir};
    return 0;
}

#
# Parse the beneficiaries page.
# Returns a bunch of accounts.
#
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

sub _set_pin_fields {
    my $agent = shift;
    my $confref = shift;

    my $page = $agent->content;

    if ( $page !~ /PIN_Val_1/s ) {
        if ( $page =~ /Session Timeout/ ) {
            print STDERR "Apparently your session timed out\n";
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

    my $form = $agent->current_form();
    for my $pd ( 1..3 ) {
        my $idx = $pin[$pd - 1];
        my $field = $form->find_input( "PIN_Val_" . $pd );
        if ( !defined( $field )) {
            croak( "failed to find PIN_Val_$pd" );
        }
        $field->readonly( 0 );
        $agent->field( "PIN_Val_" . $pd,
                       substr( $confref->{pin}, $idx -1 , 1 ));
    }
}

=back

=cut

package Finance::Bank::IE::BankOfIreland::Account;

# magic (pulled directly from other code, which I now understand)
no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
