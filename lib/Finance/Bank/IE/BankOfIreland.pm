#!/usr/bin/perl -w
#
# Banking 365ish
#
package Finance::Bank::IE::BankOfIreland;

our $VERSION = "0.08";

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
            };

my $BASEURL = "https://www.365online.com/";

use WWW::Mechanize;
use HTML::TokeParser;
use strict;
use Carp;
use Date::Parse;
use POSIX;
use Data::Dumper;

# package-local variable
my $agent;
my $lastop = 0;
my %cached_config;

sub login_dance {
    my $self = shift;
    my $confref = shift;

    $confref ||= \%cached_config;

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
        $cached_config{$required} = $confref->{$required};
    }

    if ( !defined( $agent )) {
        $agent = WWW::Mechanize->new( env_proxy => 1, autocheck => 1 );
        $agent->env_proxy;

        $agent->quiet( 0 );
        $agent->agent_alias( 'Windows IE 6' );
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
            return 1;
        }
    }

    # fetch ye login pageibus
    my $res = $agent->get( $BASEURL . 'servlet/Dispatcher/login.htm' );

    if ( !$res->is_success ) {
        croak( "Failed to get login page" );
    }

    # helpfully, BoI removed the form name, so we're going to rely on
    # it being the only form on the page for now.
    $agent->field( "USER", $confref->{user} );
    my $form = $agent->current_form();
    my $field = $form->find_input( "Password_1" );
    if ( $field->value eq "1" ) {
        $agent->field( "Pass_Val_1", $confref->{contact} );
    } elsif ( $field->value eq "2" ) {
        $agent->field( "Pass_Val_1", $confref->{dob} );
    } else {
        croak( "unrecognised secret type " . $field->value );
    }

    # now for the PIN
    for my $pd ( 1..3 ) {
        $field = $form->find_input( "PIN_Digit_" . $pd );
        my $idx = $field->value;
        $form->find_input( "PIN_Val_" . $pd )->readonly( 0 );
        $agent->field( "PIN_Val_" . $pd,
                      substr( $confref->{pin}, $idx -1 , 1 ));
    }

    $res = $agent->submit_form();

    if ( !$res->is_success ) {
        croak( "Failed to submit login form" );
    }

    my $page = $res->content;

    if ( $page !~ /Ha_Det/ ) {
        croak( "Login failed: we didn't get the Ha_Det page" );
    }

    # We need to check for the phishing page, because otherwise we're not
    # going to get any further info. Let's follow the Ha_Det link first.
    my ( $loc ) = $page =~ /Ha_Det.*location.href="\/?(.*?)"/s;
	$loc =~ s/$BASEURL//; # just in case. should really use URI to frob this.
	$res = $agent->get( $BASEURL . $loc );
    if ( !$res->is_success ) {
	     croak( "Failed to get Ha_Det page: $loc" );
	}

    # Now check if it pulls in the phishing page.
    if ( $res->content =~ m|="/?(.*?phishing_notification.html)"|s ) {
	    $res = $agent->get( $BASEURL . "/$1" );
        if ( !$res->is_success ) {
            croak( "Failed to get phishing page" );
        }
        # The page has a single form on it which we must submit
        $res = $agent->submit_form();
        if ( !$res->is_success ) {
            croak( "Failed to submit phishing page" );
        }
    }

    $lastop = time;
    return 1;
}

sub check_balance {
    my $self = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    $self->login_dance( $confref ) or return;

    # Banking frameset:
    # main frame - onlinebanking.html
    #     - subframes marbar3_pb.htm, bank.htm
    #     - bank.htm subframes navbar.htm?status=0 / accsum.htm
    my $res =
      $agent->get( $BASEURL . 'servlet/Dispatcher/accsum.htm' );

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
    while( my $tag = $parser->get_tag( "td", "th",  "/tr" )) {
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
        $text =~ s/\xa0//; # nbsp, I guess

        if ( $getheadings ) {
            push @headings, $text;
            next;
        }

        $account{$headings[$col]} = $text if $headings[$col];
        $col++;
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

    # now fetch as many pages as it's willing to give us
    my @activity;
    my @header;
    while ( 1 ) {
        $detail = $agent->content;

        my ( $hdr, $act ) = $self->parse_details( \$detail );
        push @activity, @$act;
        if ( !@header ) {
            @header = @$hdr;
        }

        if ( $detail =~ /nextform/i ) {
            $agent->submit_form( form_name => 'nextform',
                                 button => 'Next' )
              or croak( "next button failed" );
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
sub parse_details {
    my $self = shift;
    my $content = shift;
    my $parser = new HTML::TokeParser( $content );

    my ( @lines, %line, @headings );
    my ( $getheadings, $col ) = ( 1, 0 );

    while( my $tag = $parser->get_tag( "td", "th", "/tr" )) {
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
                $line{+DETBAL} ||= ( @lines ? $lines[-1]->[-1] : 0 ) +
                  $line{+CREDIT} - $line{+DEBIT};

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

    $agent->follow_link( text => $account_from )
      or croak( "Couldn't follow link to account $account_from" );

    $agent->follow_link( url_regex => qr/^navbar.htm/ )
      or croak( "Couldn't load navbar" );

    $agent->follow_link( text => "Money Transfer" )
      or croak( "Couldn't load money transfer" );

    # June 2006 update: all payments are on the one page, listed as
    # 'beneficiaries' And instead of having a nice option list,
    # there's a bunch of checkboxes, with attendant text.
    my $beneficiaries = $self->parse_beneficiaries( $agent->content );

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

    my $val;
    for my $bene ( @{$beneficiaries} ) {
        if ((( $bene->{account_no} ||'' ) eq $account_to ) or
            (( $bene->{nick} ||'' ) eq $account_to )) {
            croak "Ambiguous destination account $account_to"
              if $val;
            $val = $bene->{input};
        }
    }

    if ( !defined( $val )) {
        croak( "Unable to find $account_to in list of accounts" );
    }

    $agent->submit_form(
                        fields => {
                                   rd_pay_cancel => $val,
                                   txt_pay_amount => $amount,
                                  },
                       ) or croak( "Form submit failed" );

    my $form = $agent->current_form();
    for my $pd ( 1..3 ) {
        my $field = $form->find_input( "PIN_Digit_" . $pd );
        my $idx = $field->value;
        $form->find_input( "PIN_Val_" . $pd )->readonly( 0 );
        $agent->field( "PIN_Val_" . $pd,
                       substr( $confref->{pin}, $idx -1 , 1 ));
    }
    $agent->submit_form() or
      croak( "Payment confirm failed" );

    if ( $agent->content !~ /your request.*is confirmed/si ) {
        croak( "Payment failed" );
    }

    # return the 'receipt'
    return $agent->content;
}

#
# Parse the beneficiaries page.
# Returns a bunch of accounts.
#
sub parse_beneficiaries {
    my $self = shift;
    my $content = shift;

    my $parser = new HTML::TokeParser( \$content );

    my ( @lines, %line, @headings );
    my ( $getheadings, $col ) = ( 1, 0 );

    # first table is the 'from' account
    my $tag = $parser->get_tag( "table" );

    # second is the one we're looking for
    $tag = $parser->get_tag( "table" );

    while ( my $tag = $parser->get_tag( "td", "th", "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( $getheadings ) {
                # sanity check
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

    # first table is the 'from' account
    $tag = $parser->get_tag( "table" );

    # second is the one we're looking for
    $tag = $parser->get_tag( "table" );

    my $line = 0;
    my $input;
    while ( my $tag = $parser->get_tag( "/tr", "input" )) {
        if ( $tag->[0] eq "/tr" ) {
            push @{$lines[$line]}, $input->[1]->{value};
            $input = undef;
            $line++;
        } else {
            $input = $tag;
        }
    }

    # now clean up the whole mess.
    my @benes;
    for my $bene ( @lines ) {
        # no input -> not valid
        next unless defined( $bene->[-1] ) and $bene->[-1]
          !~ /^(pay_future|)$/;
        push @benes,
          bless {
                 type => 'Beneficiary',
                 nick => $bene->[0],
                 account_no => $bene->[1],
                 nsc => $bene->[2],
                 ref => $bene->[3],
                 desc => $bene->[4],
                 input => $bene->[5],
                }, "Finance::Bank::IE::BankOfIreland::Account";
    }

    \@benes;
}

package Finance::Bank::IE::BankOfIreland::Account;

# magic (pulled directly from other code, which I now understand)
no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
