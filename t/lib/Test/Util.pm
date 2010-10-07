=head1 NAME

Test::Util - common code for testing

=head1 SYNOPSIS



=head1 DESCRIPTION

=over

=cut

package Test::Util;

use strict;
use warnings;

=item * my $config_hashref = Test::Util::getconfig( $env );

Returns a hashref containing config for C<$env>, which it will expect to find in a file defined by C<$ENV{I<$env>CONFIG>. Returns undef if there are any problems (no such environment variable, no such file, etc.)

=cut

sub getconfig {
    my $env = shift;
    my %config;
    my $section;

    my $file = $ENV{$env . "CONFIG"};

    if ( $file ) {
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
        return \%config;
    }

    return;
}

=back

=cut

1;
