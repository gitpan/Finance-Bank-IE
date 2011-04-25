=head1 NAME

Finance::Bank::IE::PTSB - Finance::Bank interface for Permanent TSB (Ireland)

=head1 DESCRIPTION

This module implements the Finance::Bank 'API' for Permanent TSB
(Ireland)'s Open24 online banking service.

=over

=cut
package Finance::Bank::IE::PTSB;

use base qw( Finance::Bank::IE );

our $VERSION = "0.25";

use warnings;
use strict;

use Carp;
use File::Path;
use HTTP::Status;

use constant BASEURL => 'https://www.open24.ie/online/';

my %pages = (
    login => 'https://www.open24.ie/online/login.aspx',
    login2 => 'https://www.open24.ie/online/Login2.aspx',
    accounts => 'https://www.open24.ie/online/Account.aspx',
    recent => 'https://www.open24.ie/online/StateMini.aspx?ref=0',
    );

=item * $self->_get( url, [config] )

 Get the specified URL, dealing with login if necessary along the way.

=cut

sub _get {
    my $self = shift;
    my $url = shift;
    my $confref = shift;

    if ( $confref ) {
        $self->cached_config( $confref );
    }

    my ( $basename ) = $url =~ m{.*/([^/]+)$};
    $basename ||= $url;

    $self->_dprintf( " chasing '$url' ($basename)\n" );

    my $res;
    if ( $self->_agent()->find_link( url => $url )) {
        $self->_dprintf( " following $url\n" );
        $res = $self->_agent()->follow_link( url => $url );
    } else {
        $self->_dprintf( " getting $url\n" );
        $res = $self->_agent()->get( $url );
    }

    # if we get the login page then treat it as a 401
  NEXTPAGE:
    if ( $res->is_success ) {
        if ( $res->content =~ /LOGIN STEP 1 OF 2/si ) {
            if ( $basename eq 'Login2.aspx' ) {
                $self->_dprintf( " login appears to have looped, bailing to avoid lockout\n" );
                $res->code( RC_UNAUTHORIZED );
            } else {
                # do the login
                $self->_dprintf( " login step 1\n" );
                $self->_save_page();
                $self->_add_event_fields();
                # alas, this can die
                $res =
                  $self->_agent()->submit_form( fields => {
                                                           txtLogin => $confref->{user},
                                                           txtPassword => $confref->{password},
                                                           '__EVENTTARGET' => 'lbtnContinue',
                                                           '__EVENTARGUMENT' => '',
                                                          }
                                              );
                # ick
                $basename = 'Login2.aspx';

                if ( $@ ) {
                    $self->_dprintf( " $@" );
                    return;
                }

                goto NEXTPAGE;
            }
        }

        if ( $res->content =~ /LOGIN STEP 2 OF 2/si ) {
            # <td align="left"><span id="lblDigit1" class="FormStyle1">Digit No. 6</span>&nbsp;<input name="txtDigitA" type="password" maxlength="1" id="txtDigitA" tabindex="1" class="btm" size="1" onKeyup="FocusNext(1);" /></td>
            my @pins = grep /(Digit No. \d+)/, split( /[\r\n]+/, $res->content );

            my %submit;
            my @secrets = split( //, $confref->{pin} );
            for my $pin ( @pins ) {
                my ( $digit, $field ) = $pin =~
                    m{Digit No. (\d+).*input name="(.*?)"};
                my $secret = $secrets[$digit - 1];

                $submit{$field} = $secret;
            }

            $submit{'__EVENTTARGET'} = 'btnContinue';
            $submit{'__EVENTARGUMENT'} = '';

            $self->_dprintf( " login 2 of 2\n" );
            $self->_save_page();
            $self->_add_event_fields();
            $res = $self->_agent()->submit_form( fields => \%submit );

            $basename = 'Login2.aspx';
        }

        # I /think/ the default is to dump you at the account summary
        # page, in which case we redirect to the page we were actually
        # looking for.
        if ( $res->content =~ /CLICK ACCOUNT NAME FOR A MINI STATEMENT/s ) {
            if ( $url !~ /Account.aspx$/ ) {
                ( undef, $basename ) = $url =~ m{(.*/)?([^/]+)$};

                $self->_dprintf( " now chasing $url\n" );
                $self->_save_page();
                $res = $self->_agent()->get( $url );
            }
        }
    }

    $self->_save_page();

    if ( $res->is_success ) {
        return $self->_agent()->content();
    } else {
        $self->_dprintf( "  page fetch failed with " . $res->code() . "\n" );
        return undef;
    }
}

=item * check_balance( [config] )

 Check the balances on all accounts. Optional config hashref.

=cut

sub check_balance {
    my $self = shift;
    my $confref = shift;

    $confref ||= $self->cached_config();
    my $res = $self->_get( $pages{accounts}, $confref );

    return unless $res;

    # find table class="statement"
    # first is headers (account name, number-ending-with, balance, available
    # each subsequent one is an account
    my @headers;
    my @accounts;
    my $parser = new HTML::TokeParser( \$res );
    while( my $tag = $parser->get_tag( "table" )) {
        next unless ( $tag->[1]{class} || "" ) eq "statement";

        my @account;
        while( $tag = $parser->get_tag( "th", "td", "/tr", "/table" )) {
            last if $tag->[0] eq "/table";
            if ( $tag->[0] =~ /^t[hd]$/ ) {
                my $closer = "/" . $tag->[0];
                my $text = $parser->get_trimmed_text( $closer );
                if ( $tag->[0] eq "th" ) {
                    push @headers, $text;
                } else {
                    push @account, $text;
                }
            } else { # ( $tag->[0] eq "/tr" ) {
                if ( @account ) {
                    push @accounts, [ @account ];
                    @account = ();
                }
            }
        }
    }

    # match headers to data
    my @return;
    for my $account ( @accounts ) {
        my %account;

        for my $header ( @headers ) {
            my $data = shift @{$account};

            if ( $header =~ /Account Name/ ) {
                $account{type} = $data;
                $account{nick} = $data;
            } elsif ( $header =~ /Account No\./ ) {
                $account{account_no} = $data;
            } elsif ( $header =~ /Account Balance \((\w+)\)/ ) {
                $account{currency} = $1;
                $account{balance} = $data;
            }
        }
        # prune stuff we can't identify
        next if !defined( $account{balance} );
        push @return, bless \%account, "Finance::Bank::IE::PTSB::Account";
    }

    return @return;
}

=item * account_details( $account [, config] )

 Return transaction details from the specified account

=cut

sub account_details {
    my $self = shift;
    my $wanted = shift;
    my $confref = shift;

    my @details;

    $confref ||= $self->cached_config();

    my $res = $self->_get( $pages{accounts}, $confref );

    return unless $res;
    return unless $wanted;

    # this is pretty brutal
    my @likely = grep {m{(StateMini.aspx\?ref=\d+).*?$wanted}} split( /[\r\n]/, $res );
    if ( scalar( @likely ) == 1 ) {
        my ( $url ) = $likely[0] =~ m/^.*(StateMini[^"]+)".*$/;
        $res = $self->_get( $url, $confref );

        # parse!
        # there's a header table which is untagged
        # and then there's this (tblTransactions):
        # <tr>
        #       <td class="Content" align="left" valign="middle" colspan="1" width="18%">DD/MM/YYYY</td><td class="Content" align="left" valign="middle" colspan="1" width="46%">DESC</td><td class="Content" align="right" valign="middle" colspan="1" width="18%">- AMT (withdrawal) or + AMT (deposit)</td><td class="Content" align="right" valign="middle" colspan="1" width="18%">BALANCE +/-</td>
        #   </tr>

        my $parser = new HTML::TokeParser( \$res );
        while( my $tag = $parser->get_tag( "table" )) {
            if (( $tag->[1]{id}||"" ) eq "tblTransactions" ) {
                $self->_dprintf( "Found transaction table\n" );
                my @fields;
                while( my $tag = $parser->get_tag( "td", "/tr", "/table" )) {
                    if ( $tag->[0] eq "td" ) {
                        push @fields, $parser->get_trimmed_text( "/td" );
                    } elsif ( $tag->[0] eq "/tr" ) {
                        if ( @fields ) { # there are spurious blank lines
                            my ( $dr, $cr ) = ( 0, 0 );
                            if ( $fields[2] =~ /^-/ ) {
                                ( $dr = $fields[2] ) =~ s/^- //;
                            } else {
                                ( $cr = $fields[2] ) =~ s/^\+ //;
                            }

                            my ( $bal, $sign ) = $fields[3] =~ /^(.*) (.)$/;

                            push @details,
                            [
                             $fields[0],
                             $fields[1],
                             $dr,
                             $cr,
                             $sign.$bal,
                             ]
                             ;
                            @fields = ();
                        }
                    } else {
                        last;
                    }
                }
                last;
            }
        }

    } else {
        $self->_dprintf( "Found " . scalar(@likely) . " matches\n" );
        return;
    }

    unshift @details, [ 'Date', 'Desc', 'DR', 'CR', 'Balance' ];

    return @details;
}

=item * $self->_get_third_party_page( account [, config ] )

 Get the third-party payments page for account

=cut

sub _get_third_party_page {
    my $self = shift;
    my $account_from = shift;
    my $confref = shift;

    return unless $account_from;

    # allow passing in of account objects
    if ( ref $account_from eq "Finance::Bank::IE::PTSB::Account" ) {
        $account_from = $account_from->{nick};
    }

    $confref ||= $self->cached_config();
    my $res = $self->_get( $pages{accounts}, $confref );

    return unless $res;

    # XXX there's multiple of these that we need to follow to get a
    # full list of beneficiaries.
    $self->_agent()->follow_link( text => 'To Other Accounts' )
      or return 0;
    $self->_save_page();

    if ( $self->_agent()->content() =~ /third party transfer selection/is ) {
        return 1;
    }

    return 0;
}

=item * $self->list_beneficiaries( account )

 List beneficiaries of C<account>

=cut
sub list_beneficiaries {
    my $self = shift;
    my $account_from = shift;
    my $confref = shift;

    return unless $self->_get_third_party_page( $account_from, $confref );

    $self->_agent()->follow_link( text => 'Existing Third Party Transfers' );
    $self->_save_page();

    my $page = $self->_agent()->content;
    my $parser = new HTML::TokeParser( \$page );

    my @beneficiaries;
    my @beneficiary;
    while ( my $tag = $parser->get_tag( "td", "/tr" )) {
        if ( $tag->[0] eq "/tr" ) {
            if ( @beneficiary ) {
                push @beneficiaries,
                  bless {
                         type => 'Beneficiary',
                         nick => $beneficiary[0],
                         ref => $beneficiary[1],
                         input => $beneficiary[2],
                         account_no => 'hidden',
                         status => 'Active',
                        }, "Finance::Bank::IE::PTSB::Account";
                @beneficiary = ();
            }
        } elsif (( $tag->[1]{class}||"" ) eq "content" ) {
            push @beneficiary, $parser->get_trimmed_text( "/td" );
            if ( $#beneficiary == 1 ) {
                $tag = $parser->get_tag( "input" );
                push @beneficiary, $tag->[1]{value};
            }
        }
    }

    \@beneficiaries;
}

=item * $self->add_beneficiary( $from_account, $to_account_details, $config )

 Add a beneficiary to $from_account.

=cut

sub add_beneficiary {
    my ( $self, $account_from, $to_account_no, $to_nsc, $to_ref, $to_nick,
         $confref ) =
      @_;

    return unless $to_nick;
    return unless $self->_get_third_party_page( $account_from, $confref );

    # Create a new Third Party Transfer
    $self->_agent()->follow_link( text => 'Create a new Third Party Transfer' );
    $self->_save_page();

    return unless $self->_agent()->content() =~
      /CREATE A NEW THIRD PARTY TRANSFER/is;

    $self->_add_event_fields();
    $self->_agent()->submit_form(
                                 fields => {
                                            txtSortCode => $to_nsc,
                                            txtAccountCode => $to_account_no,
                                            txtBillRef => $to_ref,
                                            txtBillName => $to_nick,
                                            # if you have multiple accounts, ddlAccounts probably needs setting. Option value = NSC+Account_no!
                                            '__EVENTTARGET' => 'lbtnContinue',
                                            '__EVENTARGUMENT' => '',
                                           },
                                );
    $self->_save_page();

    return unless $self->_agent()->content() =~
      /CREATE A NEW THIRD PARTY TRANSFER.*STEP 2/si;

    $self->_add_event_fields();
    $self->_agent()->submit_form(
                                 fields => {
                                            'txtSMSCode' => '11111',
                                            '__EVENTTARGET' => 'lbtnContinue',
                                            '__EVENTARGUMENT' => '',
                                           },
                                );

    return unless $self->_agent()->content() =~
      /CREATE A NEW THIRD PARTY TRANSFER.*STEP 3/si;

    return 1;
}

=item * $scrubbed = $self->_scrub_page( $content )

 Scrub the supplied content for PII.

=cut
sub _scrub_page {
    my ( $self, $content ) = @_;

    # TODO: convert this to using a parser with inline filtering or
    # some such.

    # state variables may retain info we'd rather not pass around
    $content =~ s@(name="__(VIEWSTATE|EVENTVALIDATION).+?value=")[^"]+"@$1"@mg;

    # no sense in telling people when the account was used
    $content =~ s@(Your last successful logon was on) .*?</span>@$1 01 January 1970 at 00:00</span>@mg;

    # no bank account details, please
    while( $content =~ s@(<td.*StateMini.aspx[^>]+>)([^\0].*)$@$1<!-- ACCOUNT DETAILS -->@m ) {
        my $details = $2;
        my @cols = split( /<td/, $details );

        for my $col ( 0..$#cols ) {
            $cols[$col] =~ s@^.*</a>@\0Account Type</a>@;
            $cols[$col] =~ s@(^.*>)[0-9]{4}</td>@${1}9999</td>@;
            $cols[$col] =~ s@[0-9]+\.[0-9]{2}@99.99@g;
        }
        $details = join( '<td', @cols );
        $content =~ s/<!-- ACCOUNT DETAILS -->/$details/;
    }

    # clean up the mini statement page
    $content =~ s@lblTitle">Mini.*</span>@lblTitle">Mini Statement - Account Type - 9999</span>@;
    $content =~ s@[0-9]{2}/[0-9]{2}/[0-9]{4}@01/01/1970@mg;
    $content =~ s@[0-9]+\.[0-9]{2}@99.99@mg;
    # and finally
    1 while ( $content =~ s@(01/01/1970</td><td[^>]+>)[^<\0]+(.*)$@$ {1}\0COMMENT$ {2}@mg );
    $content =~ s/\0//gs;

    $content;
}

sub _add_event_fields {
    my $self = shift;

    # these get added by javascript on the page
    my $form = $self->_agent()->current_form();
    for my $name qw( __EVENTTARGET __EVENTARGUMENT ) {
        if ( my $input = $form->find_input( $name )) {
            $input->readonly( 0 );
        } else {
            $input = new HTML::Form::Input( type => 'text',
                                            name => $name );
            $input->add_to_form( $form );
        }
    }
}

=back

=cut

package Finance::Bank::IE::PTSB::Account;

no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
