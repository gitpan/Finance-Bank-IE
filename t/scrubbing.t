#!perl
# make sure data scrubbing works
#
# This is mainly a test for my own benefit at present to ensure I
# don't accidentally bundle something bad into the
# distribution. Longer term it should validate the scrubbing function
# of each module.
#
use warnings;
use strict;

use Test::More tests => 1;
use File::Find;

use Finance::Bank::IE::BankOfIreland;
use Finance::Bank::IE::MBNA;
use Finance::Bank::IE::PTSB;

my $pii_file = "data/pii.txt";
if ($ENV{PIIFILE}) {
    $pii_file = $ENV{PIIFILE};
}

my @pii;
open( my $pii, "<", $pii_file ) or die "$pii_file: $!";
while ( my $line = <$pii>) {
    chomp( $line );
    $line =~ s/\s+$//;
    $line =~ s/^\s+//;
    push @pii, $line;
}
close( $pii );

my $success = -1;
my $augmented_report = "";
find( { wanted => \&scrubbit, no_chdir => 1 }, "data" );
SKIP: {
    skip "no PII found", 1 if !@pii;
    skip "no files found to scrub", 1 if $success == -1;
    ok( $success == 1, "scrubbing $augmented_report" );
}

sub scrubbit {
    return unless -f $File::Find::name;
    my ( $bank ) = $File::Find::name =~ m@data/(\w+)/@;
    return unless $bank;

    # a wizard wheeze
    return if (!grep /\/$bank\.pm$/, keys %INC );

    open( my $unscrubbed, "<", $File::Find::name ) or die "$File::Find::name: $!";
    {
        local $/ = undef;
        my $content = <$unscrubbed>;
        my $scrubbed = eval "return Finance::Bank::IE::$bank->_scrub_page( \$content )";
        $augmented_report = $File::Find::name;
        if ( !$scrubbed ) {
            $success = 0;
            diag "Returned empty string when scrubbing $File::Find::name with $bank\n";
        } else {
            for my $pii ( @pii ) {
                $augmented_report = "'$pii' from " . $File::Find::name;
                if ( $scrubbed =~ /\b$pii\b/si ) {
                    $success = 0;
                    diag "$bank failed to scrub '$pii' from $File::Find::name\n";
                    last;
                }
            }
        }
    }

    # at least we scrubbed something, right?
    $success = 1 if $success == -1;
    $augmented_report = "PII from various files" if $success != 0;
}
