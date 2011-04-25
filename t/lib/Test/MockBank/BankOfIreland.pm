package Test::MockBank::BankOfIreland;

use strict;
use warnings;

use base qw( Test::MockBank );

use HTTP::Status;
use HTTP::Response;

my %pages = (
             login => '/servlet/Dispatcher/login.htm',
             login2 => '/servlet/Dispatcher/login2.htm',
             incorrect => '/servlet/Dispatcher/invalid_creds.htm',
             timeout => '/servlet/Dispatcher/timeout.htm',
             timeout2 => '/servlet/Dispatcher/365OnlineTimeout.htm',
             activate_benf => '/servlet/Dispatcher/activate_benf.htm',
            );

sub request {
    my ( $self, $response ) = @_;

    my $request = $response->request();

    my @args;
    my @args_and_equals;
    my $content;
    if ( $request->method eq 'POST' ) {
        $content = $request->content;
    } else {
        ( undef, $content ) = split( /\?/, $request->uri, 2 );
    }
    if ( $content ) {
        my @args_and_equals = split( /\&/, $content );
        for my $arg_and_equals ( @args_and_equals ) {
            my ( $key, $value ) = split( /=/, $arg_and_equals, 2 );
            push @args, [ $key, $value ];
        }
    }

    if ( !Test::MockBank->globalstate( 'loggedin' )) {
        if ( $request->uri !~ m@/(timeout|365OnlineTimeout|login|invalid_creds)\.htm$@ ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{timeout});
            Test::MockBank->globalstate( 'loggedin', 0 );
        } else {
            $response = $self->SUPER::request( $response, 'BankOfIreland' );
            if ( $request->uri =~ m@/login.htm@ ) {
                Test::MockBank->globalstate( 'loggedin', 1 );
            }
        }
    } elsif ( Test::MockBank->globalstate( 'loggedin' ) == 1 ) {
        # not sure this is strictly correct
        if ( $request->uri !~ m@/login2.htm$@ ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{timeout2} );
        } else {
            my ( $user, $password ) = ( $self->get_param( 'USER',  \@args ),
                                        $self->get_param( 'Pass_Val_1', \@args ));
            $response = $self->SUPER::request( $response, 'BankOfIreland' );
            Test::MockBank->globalstate( 'user', $user );
            Test::MockBank->globalstate( 'password', $password );
            Test::MockBank->globalstate( 'loggedin', 2 );
        }
    } else {
        if ( Test::MockBank->globalstate( 'user' ) ne
             Test::MockBank->globalstate( 'config' )->{user} ||
             Test::MockBank->globalstate( 'password') ne
             Test::MockBank->globalstate( 'config' )->{dob} ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{incorrect});
            Test::MockBank->globalstate( 'loggedin', 0 );
        } else {
            if ( $request->method eq 'POST' ) {
                if ( $self->get_param( 'activatebenf', \@args )) {
                    $response->code( RC_FOUND );
                    $response->header( 'Location' => $pages{'activate_benf'} );
                    return $response;
                }
            }
            $response = $self->SUPER::request( $response, 'BankOfIreland' );
        }
    }

    $response;
}
1;
