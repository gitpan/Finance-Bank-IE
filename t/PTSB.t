#!perl
use warnings;
use strict;

use Test::More tests => 29;

use Cwd;
use Test::MockModule;

use lib qw( t/lib );

use Test::Util;
use Test::MockBank::PTSB;

our $lwp_useragent_mock;
our $www_mechanize_mock;

BEGIN {
    $lwp_useragent_mock = new Test::MockModule( 'LWP::UserAgent' );
    $www_mechanize_mock = new Test::MockModule( 'WWW::Mechanize' );
    use_ok( "Finance::Bank::IE::PTSB" );
}

my $skipper = 1;
my $config = Test::Util::getconfig( 'PTSB' );
if ( !$config ) {
    # our fake config
    $config = {
               user => '0123456789',
               password => 'password',
               pin => '123456',
              };

    # this is our fake bank server
    $lwp_useragent_mock->mock( 'simple_request', \&Test::MockBank::simple_request );

    $skipper = 0;
} else {
    print "# Running live tests\n" if $ENV{DEBUG};
}
Test::MockBank->globalstate( 'config', $config );

my @accounts = Finance::Bank::IE::PTSB->check_balance( $config );
ok( @accounts, "can retrieve accounts" );
isa_ok( $accounts[0], "Finance::Bank::IE::PTSB::Account", "account" );
ok( $accounts[0]->{account_no}, "account has an account number" );

my $test_account = $accounts[0];

# reset state
ok( Finance::Bank::IE::PTSB->reset, "can reset object" ) and
    Test::MockBank->globalstate( 'loggedin', 0 );

my ( @details ) = Finance::Bank::IE::PTSB->account_details( $test_account->{account_no}, $config );
ok( @details, "can fetch details" );

( @details ) = Finance::Bank::IE::PTSB->account_details( undef, $config );
ok( !@details, "no account details if no account specified" );

( @details ) = Finance::Bank::IE::PTSB->account_details( 'bogus', $config );
ok( !@details, "no account details if invalid account specified" );

# list_beneficiaries
Finance::Bank::IE::PTSB->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
my $beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries( $test_account, $config );
ok( $beneficiaries, "can list beneficiaries" );

$beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries();
ok( !$beneficiaries, "no beneficiaries if no account specified" );

$beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries( $test_account->account_no );
ok( $beneficiaries, "can pass account as account number" );

# add_beneficiary
my @new_beneficiary = ( '99999999', '999999', 'An account', 'A nickname' );
Finance::Bank::IE::PTSB->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );

# insufficient fields
ok( !Finance::Bank::IE::PTSB->add_beneficiary( $test_account, $new_beneficiary[0] ), "add_beneficiary fails unless enough fields are given" );

my $beneficiary_add;
ok( $beneficiary_add = Finance::Bank::IE::PTSB->add_beneficiary( $test_account, @new_beneficiary, $config ), "add_beneficiary adds a beneficiary" );

# test use of cached config (and first make sure we /have/ cached config)
Test::MockBank->globalstate( 'loggedin', 0 );
( @details ) = Finance::Bank::IE::PTSB->account_details( $test_account->{account_no}, $config );
Test::MockBank->globalstate( 'loggedin', 0 );
( @details ) = Finance::Bank::IE::PTSB->account_details( $test_account->{account_no} );
ok( @details, "cached config (account_details)" );
Test::MockBank->globalstate( 'loggedin', 0 );
@accounts = Finance::Bank::IE::PTSB->check_balance();
ok( @accounts, "cached config (check_balance)" );
Test::MockBank->globalstate( 'loggedin', 0 );
$beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries( $test_account );
ok( $beneficiaries, "cached config (list beneficiaries)" );

Finance::Bank::IE::PTSB->reset and
    Test::MockBank->globalstate( 'loggedin', 0 );
( @details ) = Finance::Bank::IE::PTSB->account_details( $test_account->{account_no}, $config );
ok( @details, "can fetch details directly" );

# _scrub_page
{
    local $/ = undef;
    open( my $unscrubbed, "<", "data/PTSB/unscrubbed" );
    my $content = <$unscrubbed>;
    my $scrubbed = Finance::Bank::IE::PTSB->_scrub_page( $content );
    ok( $scrubbed, "_scrub_page" );
}

SKIP:
{
    skip "these tests don't work against the live site", 3 if $skipper;

    # some failure scenarios
    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );

    # if we get a page failure, it should trip up the code but not
    # cause it to crash
    Test::MockBank->fail_on_iterations( 1 );
    @accounts = Finance::Bank::IE::PTSB->check_balance( $config );
    ok( !@accounts, "can handle page-load failure (check_balance)" );

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 1 );
    ( @details ) = Finance::Bank::IE::PTSB->account_details( $test_account, $config );
    ok( !@details, "can handle page-load failure (account_detail)" );

    # this checks the _third_party code as well
    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 5 );
    $beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries( $test_account,
                                                                  $config );
    ok( !$beneficiaries, "can handle page-load failure (list_beneficiaries 1)");

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 6 );
    $beneficiaries = Finance::Bank::IE::PTSB->list_beneficiaries( $test_account,
                                                                  $config );
    ok( !$beneficiaries, "can handle page-load failure (list_beneficiaries 2)");

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 5 );
    $beneficiary_add = Finance::Bank::IE::PTSB->add_beneficiary( $test_account, @new_beneficiary, $config );
    ok( !$beneficiary_add, "can handle page-load failure (add_beneficiary)");

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 7 );
    $beneficiary_add = Finance::Bank::IE::PTSB->add_beneficiary( $test_account, @new_beneficiary, $config );
    ok( !$beneficiary_add, "can handle page-load failure (add_beneficiary 2)");

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 8 );
    $beneficiary_add = Finance::Bank::IE::PTSB->add_beneficiary( $test_account, @new_beneficiary, $config );
    ok( !$beneficiary_add, "can handle page-load failure (add_beneficiary 2)");

    Finance::Bank::IE::PTSB->reset and
        Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->fail_on_iterations( 9 );
    $beneficiary_add = Finance::Bank::IE::PTSB->add_beneficiary( $test_account, @new_beneficiary, $config );
    ok( !$beneficiary_add, "can handle page-load failure (add_beneficiary 2)");

    # looping login page
    Test::MockBank->fail_on_iterations( 0 );
    Test::MockBank->globalstate( 'loggedin', 0 );
    Test::MockBank->globalstate( 'loop', 1 );
    @accounts = Finance::Bank::IE::PTSB->check_balance( $config );
    ok( !@accounts, "can handle looping login page" );

    Test::MockBank->globalstate( 'loop', 0 );
}

# utterly bogus URL (mainly for coverage)
Test::MockBank->globalstate( 'loggedin', 0 );
my $return = Finance::Bank::IE::PTSB->_get( 'breakit', $config );
ok( !defined( $return ), "bogus url" );
$return = Finance::Bank::IE::PTSB->_get( 'breakit' );
ok( !defined( $return ), "bogus url" ) or diag $return;
