package Curator::Base;
# ABSTRACT: Base module for all curator modules

use strict;
use warnings;

# VERSION

use Import::Into;
use Module::Runtime qw( use_module );

sub modules {
    my ( $class, %args ) = @_;
    return (
        strict   => [],
        warnings => [],
        feature  => ':5.10',
    );
}

sub import {
    my ( $class, %args ) = @_;
    my %modules = $class->modules( %args );
    for my $mod ( keys %modules ) {
        use_module( $mod )->import::into( scalar caller, $modules{ $mod } );
    }
}

1;

=head1 SYNOPSIS

    package Curator::MyModule;
    use Curator::Base;

=head1 DESCRIPTION

This module imports the base set of modules for all other Curator modules.

Included in this set are:

=over 4

=item strict

=item warnings

=item feature :5.10

=back

=function modules( %args )

Return a hash of MODULE => [ IMPORTS ] to be imported. This may be overridden
by subclasses.

%args is a hash of name/value pairs that are passed in to import:

    use Curator::Base name => 'value';

