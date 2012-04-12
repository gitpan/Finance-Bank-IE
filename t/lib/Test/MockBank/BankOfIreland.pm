package Test::MockBank::BankOfIreland;

use strict;
use warnings;

use base qw( Test::MockBank );

use HTTP::Status;
use HTTP::Response;

use Finance::Bank::IE::BankOfIreland;

my %pages = Finance::Bank::IE::BankOfIreland::_pages();

sub request {
    my ( $self, $response ) = @_;

    my $request = $response->request();

    my @args;
    my @args_and_equals;
    my $content;
    ( undef, $content ) = split( /\?/, $request->uri, 2 );
    $content ||= "";
    if ( $request->method eq 'POST' ) {
        $content = join( '&', $content, $request->content );
    }
    if ( $content ) {
        my @args_and_equals = split( /\&/, $content );
        for my $arg_and_equals ( @args_and_equals ) {
            my ( $key, $value ) = split( /=/, $arg_and_equals, 2 );
            push @args, [ $key, $value ];
        }
    }

    if ( !Test::MockBank->globalstate( 'loggedin' )) {
        if ( $request->uri ne $pages{login}->{url} and
             $request->uri ne $pages{badcreds}->{url} ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{expired}->{url} );
            Test::MockBank->globalstate( 'loggedin', 0 );
        } else {
            $response = $self->SUPER::request( $response, 'BankOfIreland' );
            if ( $request->uri eq $pages{login}->{url} ) {
                Test::MockBank->globalstate( 'loggedin', 1 );
            }
        }
    } elsif ( Test::MockBank->globalstate( 'loggedin' ) == 1 ) {
        # posted back to $pages{login}
        if ( $request->uri ne $pages{login}->{url} ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{timeout2} );
        } else {
            my ( $user, $password ) =
              (
               $self->get_param( 'form:userId',  \@args ),
               #               $self->get_param( 'form:phoneNumber', \@args ),
               join( '/',
                     $self->get_param( 'form:dateOfBirth_date', \@args ),
                     $self->get_param( 'form:dateOfBirth_month', \@args ),
                     $self->get_param( 'form:dateOfBirth_year', \@args )
                   )
              );

            $response = $self->SUPER::request( $response, 'BankOfIreland' );
            Test::MockBank->globalstate( 'user', $user );
            Test::MockBank->globalstate( 'password', $password );
            Test::MockBank->globalstate( 'loggedin', 2 );
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{login2}->{url} );
        }
    } else {
        # loggedin == 2
        if ( $request->url eq $pages{login}->{url}) {
            # hack to allow login_dance to loop
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{accounts}->{url});
        } elsif ( $request->uri eq $pages{login2}->{url}) {
            # if continue was clicked, process the form, otherwise
            # just hand back the page as-is.
            if ( $self->get_param( 'form:continue', \@args )) {
                my $digits_ok = 0;
                my $digits_submitted = 0;
                my $expected = Test::MockBank->globalstate( 'config' )->{pin};

                for my $index ( 1..6 ) {
                    my $digit = $self->get_param( "form:security_number_digit$index", \@args );
                    next unless defined( $digit );
                    if ( defined( $digit )) {
                        $digits_submitted++;
                        if ( substr( $expected, $index - 1, 1 ) eq $digit ) {
                            $digits_ok++;
                        }
                    }
                }

                if ( Test::MockBank->globalstate( 'user' ) ne
                     Test::MockBank->globalstate( 'config' )->{user} ||
                     Test::MockBank->globalstate( 'password') ne
                     Test::MockBank->globalstate( 'config' )->{dob} || # or contact
                     $digits_ok != 3 ) {
                    $response->code( RC_FOUND );
                    $response->header( 'Location' => $pages{badcreds}->{url});

                    # page contains a login form which doesn't seem to
                    # work... just loop around anyway.
                    Test::MockBank->globalstate( 'loggedin', 0 );
                } elsif ( $digits_submitted != 3 ) {
                    # need to capture pages for this
                    die "not enough digits ($digits_submitted)";
                } else {
                    print STDERR "# Successful login, redirecting to accounts page\n";
                    $response->code( RC_FOUND );
                    $response->header( 'Location' => $pages{accounts}->{url});
                }
            } else {
                print STDERR "# Landed in default handler\n";
                $response = $self->SUPER::request( $response, 'BankOfIreland' );
            }
        } elsif ( $request->uri eq $pages{manageaccounts}->{url} and
                  $request->method eq 'POST' and
                  $self->get_param( 'form:managePayees', \@args )) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{managepayees}->{url} );
            return $response;
        } else {
            # this is how they should all work...
            my ( $page ) = $request->uri =~ m@/(\w+)\?@;
            my $execution = $self->get_param( 'execution', \@args );
            my ( $e, $s ) = $execution =~ /e(\d+)s(\d+)/;

            if ( $page eq 'moneyTransfer' ) {
                # TODO: make these check inputs and respond appropriately
                if ( $s == 1 ) {
                    if ( $self->get_param( 'form:domesticPayment', \@args )) {
                        ( my $responsepage = $request->uri ) =~ s/s1$/s2/;
                        $response->code( RC_FOUND );
                        $response->header( 'Location' => $responsepage );
                        return $response;
                    }
                } elsif ( $s == 2 ) {
                    if ( $self->get_param( 'form:formActions:continue', \@args )) {
                        ( my $responsepage = $request->uri ) =~ s/s2$/s3/;
                        $response->code( RC_FOUND );
                        $response->header( 'Location' => $responsepage );
                        return $response;
                    }
                } elsif ( $s == 3 ) {
                    if ( $self->get_param( 'form:formActions:continue', \@args )) {
                        ( my $responsepage = $request->uri ) =~ s/s3$/s4/;
                        $response->code( RC_FOUND );
                        $response->header( 'Location' => $responsepage );
                        return $response;
                    }
                } elsif ( $s == 4 ) {
                    if ( $self->get_param( 'form:formActions:continue', \@args )) {
                        ( my $responsepage = $request->uri ) =~ s/s4$/s5/;
                        $response->code( RC_FOUND );
                        $response->header( 'Location' => $responsepage );

                        return $response;
                    }
                }
            }
            $response = $self->SUPER::request( $response, 'BankOfIreland' );
        }
    }

    $response;
}
1;
