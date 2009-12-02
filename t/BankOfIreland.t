#!perl
use strict;
use warnings;
use Test::More tests => 6;
use Cwd;


BEGIN {
      use_ok( "Finance::Bank::IE::BankOfIreland" );
}

SKIP: {
    my $config;
    skip "No config available, skipping live tests", 4
        unless $config = getconfig( 'BOI' );

    $config->{croak} = 1;
    $config->{debugdir} = getcwd . "/data";
    #$config->{debug} = 1; # hmm.

    # can we log in?
    ok( Finance::Bank::IE::BankOfIreland->login_dance( $config ),
        "log in to BoI" );

    my @accounts;
    ok( @accounts = Finance::Bank::IE::BankOfIreland->check_balance(),
        "retrieve balances from BoI" );

    my $testaccount = shift @accounts;
    ok( Finance::Bank::IE::BankOfIreland->account_details( $testaccount->nick ), "get details for BoI account " . $testaccount->nick );

    my $benes;
    ok( $benes = Finance::Bank::IE::BankOfIreland->list_beneficiaries( $testaccount ), "get beneficiaries for BoI account " . $testaccount->nick );

    # no live test for funds transfer

    my $testbene;
    for my $bene ( @{$benes} ) {
        if ( $bene->{status} eq "Inactive" ) {
            $testbene = $bene;
            last;
        }
    }

  SKIP: {
      skip "no inactive beneficiaries", 1 unless $testbene;
      skip "no valid seven-digit code", 1;
      ok( Finance::Bank::IE::BankOfIreland->activate_beneficiary( $testaccount, $testbene, "00000000" ),
          "activated beneficiary" );
    }
}


# cheap windows-like config:
# [secret]
# key = value
sub getconfig {
    my $env = shift;
    my %config;
    my $section;

    my $file = $ENV{$env . "CONFIG"};
    return unless $file;
    open( my $FILE, "<$file" ) or return;

    while( my $line = <$FILE> ) {
        if ( $line =~ /^\[(\w+)\]$/ ) {
            $section = $1;
            next;
        }

        if ( $section eq "secret" ) {
            my ( $key, $value ) = split( /\s*=\s*/, $line, 2 );
            next unless $key;
            next unless $value;
            $key =~ s/\s+//g;
            $value =~ s/^\s+//;
            $value =~ s/\s+$//;
            $config{$key} = $value;
        }
    }

    close( $FILE );
    \%config;
}
