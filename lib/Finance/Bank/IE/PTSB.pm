#!perl
#
# Interface to Open24, Permanent TSB's online banking
#
package Finance::Bank::IE::PTSB;

our $VERSION = "0.24";

use warnings;
use strict;

use Carp;
use WWW::Mechanize;

my %cached_config;
my $agent;

use constant BASEURL => 'https://www.open24.ie/online/';

my %pages = (
    login => 'https://www.open24.ie/online/login.aspx',
    login2 => 'https://www.open24.ie/online/Login2.aspx',
    accounts => 'https://www.open24.ie/online/Account.aspx',
    recent => 'https://www.open24.ie/online/StateMini.aspx?ref=0',
    );

sub _agent {
    my $self = shift;
    if ( !$agent ) {
        $agent = new WWW::Mechanize( env_proxy => 1,
                                     autocheck => 1,
                                     keep_alive => 10 )
            or confess( "can't create agent" );
        $agent->quiet( 0 );
    }

    $agent;
}

sub _get {
    my $self = shift;
    my $url = shift;
    my $confref = shift;

    my ( $basename ) = $url =~ m{.*/([^/]+)$};
    $basename ||= $url;

    if ( $ENV{DEBUG} ) {
        print STDERR " chasing '$url' ($basename)\n";
    }

    my $res;
    if ( $self->_agent()->find_link( url => $url )) {
        print STDERR " following $url\n" if $ENV{DEBUG};
        $res = $self->_agent()->follow_link( url => $url );
    } else {
        print STDERR " getting $url\n" if $ENV{DEBUG};
        $res = $self->_agent()->get( $url );
    }

    # if we get the login page then treat it as a 401
  NEXTPAGE:
    if ( $res->is_success ) {
        if ( $res->content =~ /LOGIN STEP 1 OF 2/si ) {
            # do the login
            print STDERR " login step 1\n" if $ENV{DEBUG};
            $res = $self->_agent()->submit_form(
                fields => {
                    txtLogin => $confref->{user},
                    txtPassword => $confref->{password},
                    '__EVENTTARGET' => 'lbtnContinue',
                    '__EVENTARGUMENT' => '',
                } ) or die $!;

            # ick
            $basename = 'Login2.aspx';

            goto NEXTPAGE;
        }

        if ( $res->content =~ /LOGIN STEP 2 OF 2/si ) {
            # <td align="left"><span id="lblDigit1" class="FormStyle1">Digit No. 6</span>&nbsp;<input name="txtDigitA" type="password" maxlength="1" id="txtDigitA" tabindex="1" class="btm" size="1" onKeyup="FocusNext(1);" /></td>
            my @pins = grep /(Digit No. \d+)/, split( /[\r\n]+/, $res->content );

            my %submit;
            my @secrets = split( //, $confref->{pin} );
            for my $pin ( @pins ) {
                my ( $digit, $field ) = $pin =~
                    m{Digit No. (\d+).*input name="(.*?)"};
                if ( !$digit ) {
                    next;
                }
                my $secret = $secrets[$digit - 1];

                $submit{$field} = $secret;
            }
            $submit{'__EVENTTARGET'} = 'btnContinue';
            $submit{'__EVENTARGUMENT'} = '';

            print STDERR " login 2 of 2\n" if $ENV{DEBUG};
            $res = $self->_agent()->submit_form( fields => \%submit ) or
                die $!;

            $basename = 'Login2.aspx';
        }

        # I /think/ the default is to dump you at the account summary
        # page, in which case we redirect to the page we were actually
        # looking for.
        if ( $res->content =~ /CLICK ACCOUNT NAME FOR A MINI STATEMENT/s ) {
            if ( $url !~ /Account.aspx$/ ) {
                ( $basename ) = $url =~ m{.*/([^/]+)$};
                $basename ||= $url;

                print STDERR " now chasing $url\n" if $ENV{DEBUG};
                $res = $self->_agent()->get( $url );
            }
        }
    }

    if ( $res->is_success ) {
        if ( $ENV{DEBUG} ) {
            $self->_agent()->save_content( 'data/PTSB/' . $basename );
        }
        return $self->_agent()->content();
    } else {
        if ( $ENV{DEBUG} ) {
            $self->_agent()->save_content( 'data/PTSB/' . $res->code() . '-' . $basename );
        }
        return undef;
    }
}

sub check_balance {
    my $self = shift;
    my $confref = shift;

    $confref ||= \%cached_config;
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
            if ( $tag->[0] eq "th" or $tag->[0] eq "td" ) {
                my $closer = "/" . $tag->[0];
                my $text = $parser->get_trimmed_text( $closer );
                if ( $tag->[0] eq "th" ) {
                    push @headers, $text;
                } else {
                    push @account, $text;
                }
            } elsif ( $tag->[0] eq "/tr" ) {
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
            } elsif ( $header =~ /Available Balance/ ) {
                $account{available} = $data;
            }
        }
        # prune stuff we can't identify
        next if !defined( $account{balance} );
        push @return, bless \%account, "Finance::Bank::IE::PTSB::Account";
    }

    return @return;
}

sub account_details {
    my $self = shift;
    my $wanted = shift;
    my $confref = shift;

    my @details;

    $confref ||= \%cached_config;

    my $res = $self->_get( $pages{accounts}, $confref );

    return unless $res;

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
                print STDERR "Found transaction table\n";
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
                    } elsif ( $tag->[0] eq "/table" ) {
                        last;
                    }
                }
                last;
            }
        }

    } else {
        print STDERR "Found " . scalar(@likely) . " matches\n" if $ENV{DEBUG};
        return;
    }

    return [ 'Date', 'Desc', 'DR', 'CR', 'Balance' ], \@details;
}

package Finance::Bank::IE::PTSB::Account;

no strict;
sub AUTOLOAD { my $self=shift; $AUTOLOAD =~ s/.*:://; $self->{$AUTOLOAD} }

1;
