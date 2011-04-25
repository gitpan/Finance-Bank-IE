package Test::MockBank::MBNA;

use strict;
use warnings;

use base qw( Test::MockBank );

use HTTP::Status;
use HTTP::Response;

my %pages = (
             index => 'index.html',
             login => 'WelcomeScreen',
             loggedin => 'RegisteredAccountsScreen?login=true',
            );

sub request {
    my ( $self, $response ) = @_;

    my $request = $response->request();

    if ( !Test::MockBank->globalstate( 'loggedin' )) {
        if ( $request->uri =~ m@/(index.html|WelcomeScreen.*)?$@ ) {
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $request->uri, 'MBNA' ));
            Test::MockBank->globalstate( 'loggedin', 1 )
                if $request->uri =~ /$pages{login}/;
        } else {
            die "haven't sorted out what happens here yet";
        }
    } elsif ( Test::MockBank->globalstate( 'loggedin' ) == 1 ) {
        if ( $request->uri =~ m@LoginProcess@ ) {
            # SiteKey page
            $response->code( RC_OK );
            $response->content( Test::Util::getfile( $request->uri, 'MBNA' ));
            Test::MockBank->globalstate( 'loggedin', 2 );
        } else {
            die "haven't sorted out what happens here, either";
        }
    } else {
        if ( $request->uri =~ m@LoginProcess@ ) {
            $response->code( RC_FOUND );
            $response->header( 'Location' => $pages{loggedin});
        } else {
            $response = $self->SUPER::request( $response, 'MBNA' );
        }
    }

    $response;
}

1;
