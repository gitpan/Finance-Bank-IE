#!/usr/bin/perl -w
#
# Banking 365ish
#
package Finance::Bank::IE::BankOfIreland;

our $VERSION = "0.07";

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

sub funds_transfer {
    my $self = shift;
    my $account_from = shift;
    my $account_to = shift;
    my $amount = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
    login_dance( $confref ) or return;

    # allow passing in of account objects
    if ( ref $account_from eq "HASH" and defined( $account_from->{nick} )) {
        $account_from = $account_from->{nick};
    }

    if ( ref $account_to eq "HASH" and defined( $account_to->{nick} )) {
        $account_to = $account_to->{nick};
    }

    $agent->follow_link( text => $account_from )
      or croak( "Couldn't follow link to account $account_from" );

    $agent->follow_link( url_regex => qr/^navbar.htm/ )
      or croak( "Couldn't load navbar" );

    $agent->follow_link( text => "Money Transfer" )
      or croak( "Couldn't load money transfer" );

    #
    # June 2006 update: all payments are on the one page, listed as
    # 'beneficiaries' And instead of having a nice option list,
    # there's a bunch of checkboxes, with attendant text.
    my $beneficiaries = $self->parse_beneficiaries( $agent->content );

    my $val;
    for my $bene ( @{$beneficiaries}) {
        $val = $bene->[-1] if ( $bene->[0] ||'' ) eq $account_to;
        $val = $bene->[-1] if ( $bene->[1] ||'' ) eq $account_to;
        last if $val;
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

    # return the 'receipt'
    return $agent->content;
}

#
# Parse the beneficiaries page. Returns a ref of data (containing some
# undefs) which ties a nickname and an account number to a setting for
# the rd_pay_cancel radiobutton.
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

            # now convert the date
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

    \@lines;
}

package Finance::Bank::IE::BankOfIreland::Account;

# magic (pulled directly from other code, which I now understand)
no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
