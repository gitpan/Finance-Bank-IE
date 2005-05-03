#!/usr/bin/perl -w
#
# demo of Finance::Bank::IE::BankOfIreland interface
use lib $ENV{HOME} . "/src/perl";
use Finance::Bank::IE::BankOfIreland;

# fill out as appropriate
my %config = (
              "user" => "",
              "pin" => "",
              "contact" => "",
              "dob" => "",
              "croak" => 1
             );

my @accounts = Finance::Bank::IE::BankOfIreland->check_balance( \%config );

# display account balance
foreach ( @accounts ) {
    printf "%8s : %s %8.2f\n",
	  $_->{account_no}, $_->{currency}, $_->{balance};
}

# display recent activity
foreach ( @accounts ) {
    my @activity = Finance::Bank::IE::BankOfIreland->account_details( $_ );
    for my $line ( @activity ) {
        my @cols = @{$line};
        # cols are date, comment, dr, cr, balance
        # last three may contain blanks
        # date contains non-breaking spaces (blech)
        for my $col ( 0..$#cols) {
            printf( "[%s]", $cols[$col]);
        }
        print "\n";
    }
}
