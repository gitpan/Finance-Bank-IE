package Test::MockBank;

use warnings;
use strict;

use HTTP::Status;
use HTTP::Response;
use URI::Escape;

my %GLOBALSTATE = (
                   loggedin => 0,
                   config => {},
                  );

sub globalstate {
    my $self = shift;
    my ( $key, $value ) = @_;

    if ( defined( $value )) {
        $GLOBALSTATE{$key} = $value;
    }

    $GLOBALSTATE{$key};
}

sub fail_on_iterations {
    my $self = shift;
    my $iterations = [ @_ ];
    $self->globalstate( 'fail', [ $iterations, 0 ] );
}

sub on_page {
    my $self = shift;
    my $uri = shift;
    my $usepage = shift;

    $self->globalstate( 'on_page', [ $uri, $usepage ] );
}

sub simple_request {
    my ( $self, $request ) = @_;

    print STDERR "# Mock Bank request for " . $request->uri . ", login state " .
      ( Test::MockBank->globalstate( 'loggedin' )||0) . "\n"
      if $ENV{DEBUG};

    my $response = new HTTP::Response();
    $response->request( $request );

    if ( my $fail = Test::MockBank->globalstate( 'fail' )) {
        my ( $failures, $iteration ) = @{$fail};
        $iteration++;
        Test::MockBank->globalstate( 'fail', [ $failures, $iteration ]);

        if ( grep {m/^$iteration$/} @{$failures} ) {
            print STDERR "# failing per request on iteration $iteration when " . $request->method . "ing " . $request->uri . "\n"
              if $ENV{DEBUG};
            my @iterations = grep {!m/^$iteration$/} @{$failures};
            if ( !@iterations ) {
                Test::MockBank->globalstate( 'fail', 0 );
            } else {
                Test::MockBank->globalstate( 'fail', [ \@iterations, $iteration ] );
            }
            $response->code( RC_INTERNAL_SERVER_ERROR );
            $response->content( 'FAIL' );
            return $response;
        } else {
        }
    }

    if ( my $substitute = Test::MockBank->globalstate( 'on_page' )) {
        my $uri = $request->uri;
        if ( $uri eq $substitute->[0] ) {
            $request->uri( $substitute->[1] );
        }
    }

    # a little fragile perhaps
    my $context = $0;
    $context =~ s@t/(.*)\.t$@$1@;

    eval '$response = Test::MockBank::' . $context . '->request( $response, $context );';
    die "$context: $@" if $@;

    print STDERR "# returning " . $response->code . "\n" if $ENV{DEBUG};

    return $response;
}

sub request {
    my ( $self, $response, $context ) = @_;

    my $request = $response->request();

    my $content = Test::Util::getfile( $request->uri, $context );
    if ( defined( $content )) {
        $response->code( RC_OK );
        $response->content( $content );
    } else {
        $response->code( RC_NOT_FOUND );
        $response->message( 'file not found' );
        $response->content( 'no such uri ' . $request->uri );
    }

    $response;
}

sub get_param {
    my ( $self, $param, $args ) = @_;

    my $value;
    map {
        $value = $_->[1] if $_->[0] eq $param;
    } @{$args};

    $value = uri_unescape( $value );

    $value;
}

1;
