#!/usr/bin/perl -w
#
# Banking 365ish
#
package Finance::Bank::IE::BankOfIreland;

our $VERSION = "0.03";

my $BASEURL = "https://www.365online.com/";

use WWW::Mechanize;
use HTML::TokeParser;
use strict;
use Carp;
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

    $agent->form_name( "usid" );
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

    my $step = 0;
    my @accounts;
    my @account;
    while ( my $token = $parser->get_tag( "td" )) {
        my $text = $parser->get_trimmed_text( "/td" );
        if ( $step == 0 ) {
            next unless $text =~ /Current|Savings/; # xxx skip credit cards
            $step = 1;
            @account = ( $text );
            next;
        }

        if ( $step ) {
            push @account, $text;
            $step++;
            if ( $step == 9 ) {
                $account[8] =~ s/[^0-9.-]//g;
                push @accounts,
                  bless {
                         type => $account[0],
                         nick => $account[2],
                         account_no => $account[4],
                         currency => $account[6],
                         balance => $account[8],
                        }, "Finance::Bank::IE::BankOfIreland::Account";
                $step = 0;
            }
        }
    }

    return @accounts;
}

sub account_details {
    my $self = shift;
    my $account = shift;
    my $confref = shift;

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

sub parse_details {
    my $self = shift;
    my $content = shift;
    my $parser = new HTML::TokeParser( $content );

    # header
    $parser->get_tag( "table" );
    $parser->get_tag( "/table" );

    # find the account details table
    $parser->get_tag( "table" );

    my @lines;
    my @line;
    my @header;

    # we're expecting the Date to be the first header.
    my $lastdate = "";

    while ( my $token = $parser->get_token ) {
        last if ( $token->[0] eq "E" and $token->[1] eq "table" );
        if ( $token->[0] eq "S" ) {
            if ( $token->[1] eq "th" ) {
                push @header, $parser->get_trimmed_text( "/th" );
            }
            if ( $token->[1] eq "td" ) {
                push @line, $parser->get_trimmed_text( "/td" );
            }
        } elsif ( $token->[0] eq "E" and $token->[1] eq "tr" ) {
            # skip blanks
            next unless $#line > -1;

            # skip currency header
            if ( $line[-1] eq "EUR" or $#line < 4 ) {
                $#line = -1;
                next;
            }

            # fixup. I hate BOI's HTML
            shift @line; # blank at start

            # seems to be extra space on the first line - might be
            # crap code on my part.
            if ( $#lines == -1 ) {
                shift @line;
                shift @line;
                shift @line;
            }

            my @copy = @line;
            $#line = -1;

            # patch in the date from the previous line if necessary
            if ( $copy[0] =~ /^\s*$/ ) {
                $copy[0] = $lastdate;
            }
            $lastdate = $copy[0];

            # patch in missing values for dr/cr
            for my $i ( -2, -3 ) {
                $copy[$i] ||= "0.00";
            }

            push @lines, \@copy;
        } else {
        }
    }

    # there's a blank at the start of the header
    shift @header;

    return \@header, \@lines;
}

package Finance::Bank::IE::BankOfIreland::Account;

# magic (pulled directly from other code, which I now understand)
no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
