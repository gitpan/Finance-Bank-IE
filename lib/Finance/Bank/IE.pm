=head1 NAME

Finance::Bank::IE - shared functions for the Finance::Bank::IE module tree

=head1 DESCRIPTION

This module implements a few shared functions for Finance::Bank::IE::*

=over

=cut

package Finance::Bank::IE;

use File::Path;
use WWW::Mechanize;
use Carp qw( confess );

use strict;
use warnings;

our $VERSION = "0.27";

# Class state. Each of these is keyed by the hash value of $self to
# provide individual class-level variables. Ideally I'd just hack the
# namespace of the subclass, though.
my %agent;
my %cached_config;

=item * $self->reset()

 Take necessary steps to reset the object to a pristine state, such as deleting cached configuration, etc.

=cut

sub reset {
    my $self = shift;

    $agent{$self} = undef;
    $cached_config{$self} = undef;;

    return 1;
}

=item * $self->_agent

 Return the WWW::Mechanize object currently in use, or create one if
 no such object exists.

=cut

sub _agent {
    my $self = shift;

    if ( !$agent{$self} ) {
        $agent{$self} = WWW::Mechanize->new( env_proxy => 1,
                                             autocheck => 0,
                                             keep_alive => 10 );
        if ( !$agent{$self}) {
            confess( "can't create agent" );
        }
        $agent{$self}->quiet( 0 );
    }

    $agent{$self};
}

=item * $self->cached_config( [config] )

  Get or set the cached config

=cut
sub cached_config {
    my ( $self, $config ) = @_;
    if ( defined( $config )) {
        $cached_config{$self} = $config;
    }

    return $cached_config{$self};
}

=item * $class = $self->_get_class()

 Return the bottom level class of $self

=cut
sub _get_class {
    my $self = shift;
    my $class = ref( $self );

    if ( !$class ) {
        $class = $self;
    }

    # clean it up
    my $basename = ( split /::/, $class )[-1];
    $basename =~ s/\.[^.]*$//;

    $basename;
}

=item * $scrubbed = $self->_scrub_page( $content )

 Scrub the supplied content for PII.

=cut
sub _scrub_page {
    my ( $self, $content ) = @_;

    return $content;
}

=item * $self->_save_page()

 Save the current page if $ENV{SAVEPAGES} is set. The pages are
 anonymised before saving so that they can be used as test pages
 without fear of divulging any information.

=cut

sub _save_page {
    my $self = shift;
    my @params = @_;
    return unless $ENV{SAVEPAGES};

    # get a filename from the agent
    my $res = $self->_agent()->response();
    my $filename = $res->request->uri();
    $filename =~ s@^.*/@@;
    if ( !$filename ) {
        $filename = "index.html";
    }

    # embed the code if it's a failed page
    if ( !$res->is_success()) {
        $filename = $res->code() . "-$filename";
    }

    if ( @params ) {
        $filename .= '?' . join( '&', @params );
    }

    my $path = 'data/savedpages/' . $self->_get_class();
    mkpath( [ $path ], 0, 0700 );
    $filename = "$path/$filename";

    $self->_dprintf( "writing data to $filename\n" );

    # we'd like to anonymize this content before saving it.
    my $content = $self->_agent()->content();

    $content = $self->_scrub_page( $content );

    my $error = 0;
    if ( open( my $FILEHANDLE, ">", $filename )) {
        binmode $FILEHANDLE, ':utf8';
        print $FILEHANDLE $content;
        close( $FILEHANDLE );
    } else {
        $error = $!;
        warn "Failed to create $filename: $!";
    }

    return $error;
}

=item * $self->_streq( $a, $b )

 Return $a eq $b; if either is undef, substitutes an empty string.

=cut

sub _streq {
    my ( $self, $a, $b ) = @_;

    $a = "" if !defined( $a );
    $b = "" if !defined( $b );

    return $a eq $b;
}

=item * $self->_rebuild_tag( $html_tokeparser_decomposed_tag )

 Return C<html_tokeparser_decomposed_tag> as a composed HTML tag.

=cut

sub _rebuild_tag {
    my $self = shift;
    my $data = shift;
    my $tag = $data->[1];
    if ( $data->[0] eq 'E' ) {
        $tag = "/$tag";
    }
    my $attr_values = $data->[2];
    my $attr_order = $data->[3];
    my @rebuild = "<$tag";
    for my $attr ( @{$attr_order} ) {
        next unless exists($attr_values->{$attr});
        my $attrstring = "$attr=";
        my $attrvalue = $attr_values->{$attr};
        $attrvalue =~ s@\\@\\\\@g;
        $attrvalue =~ s@"@\\"@g;
        $attrstring .= "\"$attrvalue\"";
        push @rebuild, $attrstring;
    }
    return join( ' ', @rebuild ) . ">";
}

=item * $self->_dprintf( ... )

 Print to STDERR using printf formatting if $ENV{DEBUG} is set.

=cut

sub _dprintf {
    my $self = shift;
    binmode( STDERR, ':utf8' );

    if ( $ENV{DEBUG}) {
        printf STDERR "[%s] ", ref( $self ) || $self || "DEBUG";
        printf STDERR @_ if $ENV{DEBUG};
    }
}

=item * $self->_as_qif( $account_details_array_ref[, $type ] )

 Render C<$account_details_array_ref> as QIF. I<Very>
 limited. Optional C<$type> is the type of account.

 C<$account_details_array_ref> should be an arrayref of hashrefs, each
 containing the date, the payee, and the amount. Negative amounts
 indicate debits.

=cut

sub as_qif {
    my $self = shift;
    my $details_aref = shift;
    my $type = shift || "Bank";

    my $qif = "!Type:Bank\n";

    for my $details ( @{$details_aref} ) {
        $qif .= sprintf("D%s
P%s
T%0.02f
^
", $details->{date}, $details->{payee}, $details->{amount});
    }

    return $qif;
}

=back

=cut

1;
