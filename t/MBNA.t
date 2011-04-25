#!perl -w
use warnings;
use strict;

use Test::More tests => 18;

use Test::MockModule;

use lib qw( t/lib );

use Test::Util;
use Test::MockBank::MBNA;
use Data::Dumper;

our $lwp_useragent_mock;
our $www_mechanize_mock;

BEGIN {
    $lwp_useragent_mock = new Test::MockModule( 'LWP::UserAgent' );
    $www_mechanize_mock = new Test::MockModule( 'WWW::Mechanize' );
    use_ok( "Finance::Bank::IE::MBNA" );
}

my $skipper = 1;
my $config = Test::Util::getconfig( 'MBNA' );
if ( !$config ) {
    # our fake config
    $config = {
               user => '0123456789',
               password => 'password',
              };

    # this is our fake bank server
    $lwp_useragent_mock->mock( 'simple_request', \&Test::MockBank::simple_request );

    $skipper = 0;
} else {
    print "# Running live tests\n" if $ENV{DEBUG};
}
Test::MockBank->globalstate( 'config', $config );

my @accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( @accounts, "can retrieve accounts" );
ok( scalar(@accounts) == 2, "found two accounts" );
isa_ok( $accounts[0], "Finance::Bank::IE::MBNA::Account", "account" );
ok( $accounts[0]->{account_no}, "account has an account number" );
ok( $accounts[0]->{balance} eq 77.39, "found correct balance" )
    or diag "balance was " . $accounts[0]->{balance};

# account zero has no transactions
my $test_account = $accounts[1];

# reset state
ok( Finance::Bank::IE::MBNA->reset, "can reset object" ) and
    Test::MockBank->globalstate( 'loggedin', 0 );

my ( @details ) = Finance::Bank::IE::MBNA->account_details( $test_account->{account_no}, $config );
ok( @details, "can fetch details" );

# cached config
Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
( @details ) = Finance::Bank::IE::MBNA->account_details( $test_account->{account_no}, $config );
Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Finance::Bank::IE::MBNA->account_details( $test_account->{account_no} );
ok( @details, "cached config (account_details)" );

# missing required fields
Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
( @details ) = Finance::Bank::IE::MBNA->account_details( $test_account->{account_no}, {} );
ok( !@details, "missing username" );
( @details ) = Finance::Bank::IE::MBNA->account_details( $test_account->{account_no}, { user => $config->{user}} );
ok( !@details, "missing password" );

# some failure scenarios
Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 1 );
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (root page)" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 2 );
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (WelcomeScreen)" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 3 );
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (LoginProcess (username))" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 4 );
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (LoginProcess (password))" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 5 );
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (Account Screen)" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 6, 7 ); # need to fail both cards
@accounts = Finance::Bank::IE::MBNA->check_balance( $config );
ok( !@accounts, "can handle page-load failure (Account Snapshot)" );

Finance::Bank::IE::MBNA->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
Test::MockBank->fail_on_iterations( 6, 7 );
@accounts = Finance::Bank::IE::MBNA->account_details( $test_account->{account_no}, $config );
ok( !@accounts, "can handle page-load failure (Account Snapshot 2)" );
