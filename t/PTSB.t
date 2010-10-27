#!perl
use warnings;
use strict;
use Test::More tests => 5;
use Cwd;

use lib qw( t/lib );
use Test::Util;

BEGIN {
      use_ok( "Finance::Bank::IE::PTSB" );
}

SKIP: {
    my $config = Test::Util::getconfig( 'PTSB' );

    skip "No config available, skipping live tests", 4 unless $config;

    my @accounts = Finance::Bank::IE::PTSB->check_balance( $config );
    ok( @accounts, "can retrieve accounts" );
    isa_ok( $accounts[0], "Finance::Bank::IE::PTSB::Account", "account" );
    ok( $accounts[0]->{account_no}, "account has an account number" );
    my ( $headers, $details ) = Finance::Bank::IE::PTSB->account_details( $accounts[0]->{account_no});
    ok( $details, "can fetch details" );
    use Data::Dumper;
    print Dumper( $details );
}
