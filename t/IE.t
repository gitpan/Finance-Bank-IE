#!perl
use strict;
use warnings;

use Test::MockModule;
use Test::More tests => 21;

use File::Basename;
use Cwd;

my $www_mechanize_mock;

BEGIN {
    $www_mechanize_mock = new Test::MockModule( 'WWW::Mechanize' );
    use_ok( "Finance::Bank::IE" );
}

# reset
ok( Finance::Bank::IE->reset(), "can reset" );

# _agent
my $agent;
ok( $agent = Finance::Bank::IE->_agent(), "can create an agent" );
Finance::Bank::IE->reset();
my $agent2 = Finance::Bank::IE->_agent();
# this is a little flaky
ok( $agent != $agent2, "reset works" ) or diag "$agent, $agent2";

# if we can't create a new WWW::Mechanize object, fail
Finance::Bank::IE->reset();
$www_mechanize_mock->mock( 'new', sub {
                               return undef
                           });
# this confess()es, so we need to catch it
$agent = undef;
eval {
    $agent = Finance::Bank::IE->_agent();
};
ok( !$agent, "can handle WWW::Mechanize new() failure" );
$www_mechanize_mock->unmock_all();

# cached_config
Finance::Bank::IE->reset();
my $config = { foo => 'bar' };
ok( !Finance::Bank::IE->cached_config(), "no config returned if none present" );
ok( my $cached = Finance::Bank::IE->cached_config( $config ), "saves config" );
is_deeply( $cached, $config, "correctly saves config" );
ok( $cached = Finance::Bank::IE->cached_config(), "retrieves cached config" );
is_deeply( $cached, $config, "correctly retrieves config" );

# _dprintf
my $savestderr = fileno( STDERR );
open my $olderr, '>&', \*STDERR or die $!;
close( STDERR );
my $stderr;
open STDERR, '>', \$stderr;
my $olddebug = delete $ENV{DEBUG};
Finance::Bank::IE->_dprintf( "hello world\n" );
ok( !$stderr, "_dprintf suppressed if DEBUG is unset" );
$ENV{DEBUG} = 1;
Finance::Bank::IE->_dprintf( "hello world\n" );
ok( $stderr eq "hello world\n", "_dprintf prints if DEBUG is set" ) or diag $stderr;

# reset everything
if ( defined( $olddebug )) {
    $ENV{DEBUG} = $olddebug;
} else {
    delete $ENV{DEBUG};
}
close( STDERR );
open STDERR, '>&', $olderr or die $!;

# _get_class
ok( Finance::Bank::IE->_get_class() eq "IE", "_get_class (class)" );
# we don't have new() just yet
my $bogus = bless {}, "Finance::Bank::IE";
ok( $bogus->_get_class() eq "IE", "_get_class (object)" );

# _scrub_page
ok( Finance::Bank::IE->_scrub_page( "foo" ) eq "foo", "_scrub_page" );

# _save_page
my $oldsave = delete $ENV{SAVEPAGES};
$agent = Finance::Bank::IE->_agent();
my $file = 'file://' . File::Spec->catfile( getcwd(), $0 );
my $bogussuffix = "doesnotexist";
my $saved1 = "data/savedpages/IE/" . basename( $0 );
my $saved2 = "data/savedpages/IE/404-" . basename( $0 ) . $bogussuffix;
my $saved3 = "data/savedpages/IE/index.html";
unlink( $saved1 );
unlink( $saved2 );
unlink( $saved3 );
$agent->get( $file );
Finance::Bank::IE->_save_page();
$agent->get( $file . $bogussuffix );
Finance::Bank::IE->_save_page();
ok( ! -e $saved1, "_save_page (off, found)" );
ok( ! -e $saved2, "_save_page (off, not found)" );
$ENV{SAVEPAGES} = 1;
$agent->get( $file );
Finance::Bank::IE->_save_page();
$agent->get( $file . $bogussuffix );
Finance::Bank::IE->_save_page();
ok( -e $saved1, "_save_page (on, found)" );
ok( -e $saved2, "_save_page (on, not found)" );

$agent->get( $file );
$agent->response()->request->uri( 'http://www.example.com/' );
Finance::Bank::IE->_save_page();
ok( -e $saved3, "_save_page (on, index.html)" );

# unsaveable file. Need to capture stderr.
chmod( 0400, $saved3 );
$savestderr = fileno( STDERR );
open $olderr, '>&', \*STDERR or die $!;
close( STDERR );
open STDERR, '>', \$stderr;
Finance::Bank::IE->_save_page();
ok( $stderr =~ m@^Failed to create $saved3: Permission denied@,
    "unwritable file" );
close( STDERR );
open STDERR, '>&', $olderr or die $!;

if ( defined( $oldsave )) {
    $ENV{SAVEPAGES} = $oldsave;
} else {
    delete $ENV{SAVEPAGES};
}
