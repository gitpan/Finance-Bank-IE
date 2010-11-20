#!perl -w
use warnings;
use strict;
use Test::More tests => 2;

use lib qw( t/lib );
use Test::Util;

BEGIN {
      use_ok( "Finance::Bank::IE::MBNA" );
}

SKIP: {
    my $config = Test::Util::getconfig( 'MBNA' );
    skip "No config available, skipping live tests", 1 unless $config;
    my @accounts = Finance::Bank::IE::MBNA->check_balance( $config );
    ok( @accounts, "can retrieve accounts" );
}
