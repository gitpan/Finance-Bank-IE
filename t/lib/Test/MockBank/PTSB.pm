package Test::MockBank::PTSB;

use strict;
use warnings;

use base qw( Test::MockBank );

use HTTP::Status;
use HTTP::Response;

my %pages = (
             login => '/online/login.aspx?ref5',
             logoff => '/online/DoLogOff.aspx?ref0',
             login2 => '/online/Login2.aspx',
             incorrect => '/online/Incorrect1.aspx',
             loggedin => '/online/Account.aspx',
             add3p => '/online/TPTcreate.aspx',
             add3p2 => '/online/TPTcreateconfirm.aspx',
             add3pok => '/online/TPTCreateConfirmed.aspx',
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

    if ( !Test::MockBank->globalstate( 'loggedin' ) ) {
        if ( $request->uri =~ m@/login.aspx[^/]*$@ ) {
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $pages{login}, 'PTSB' ));
            Test::MockBank->globalstate( 'loggedin', 1 );
        } else {
            # account.aspx redirects to login.aspx?ref5
            # locked-out.aspx redirects to login.aspx?ref7
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{login} );
        }
    } elsif ( Test::MockBank->globalstate( 'loggedin' ) == 1 ) {
        if ( my $loop = Test::MockBank->globalstate( 'loop' )) {
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $pages{login}, 'PTSB' ));
            Test::MockBank->globalstate( 'loop', $loop - 1 );
            return $response;
        }

        my ( $user, $password ) = ( $self->get_param( 'txtLogin', \@args ),
                                    $self->get_param( 'txtPassword', \@args ));
        if ( !$user || !$password ) {
            # seriously - this is how it behaves
            Test::MockBank->globalstate( 'loggedin', 0 );
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $pages{logoff}, 'PTSB' ));
        } else {
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $pages{login2}, 'PTSB' ));
            Test::MockBank->globalstate( 'loggedin', 2 );
            Test::MockBank->globalstate( 'user', $user );
            Test::MockBank->globalstate( 'password', $password );
        }
    } else {
        # if we get this far we've submitted a username & password, so
        # validate it.
        if ( Test::MockBank->globalstate( 'user' ) ne
             Test::MockBank->globalstate( 'config' )->{user} ||
             Test::MockBank->globalstate( 'password' ) ne
             Test::MockBank->globalstate( 'config' )->{password}) {
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $pages{incorrect}, 'PTSB' ));
            Test::MockBank->globalstate( 'loggedin', 0 );
        } else {
            # valid credentials. special redirect handling at this point.
            my $submitted = $self->get_param( '__EVENTTARGET', \@args ) || "";
            if ( $request->uri =~ /Login2.aspx/ ) {
                $response->code( RC_FOUND );
                $response->header( 'Location' => $pages{loggedin} );
            } elsif ( $request->uri =~ $pages{add3p} and
                      $submitted eq 'lbtnContinue' ) {
                $response->code( RC_FOUND );
                $response->header( 'Location' => $pages{add3p2} );
            } elsif ( $request->uri =~ $pages{add3p2} and
                      $submitted eq 'lbtnContinue' ) {
                my $code = $self->get_param( 'txtSMSCode', \@args );
                # don't have the fail page for this yet
                #if ( $code eq Test::MockBank->globalstate( 'txtSMSCode' )) {
                #}
                $response->code( RC_FOUND );
                $response->header( 'Location' => $pages{add3pok} );
            } else {
                $response = $self->SUPER::request( $response, 'PTSB' );
            }
        }
    }

    $response;
}

1;
