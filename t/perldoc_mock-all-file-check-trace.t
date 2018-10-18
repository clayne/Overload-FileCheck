#!/usr/bin/perl -w

use strict;
use warnings;

use Test2::Bundle::Extended;
use Test2::Tools::Explain;
use Test2::Plugin::NoWarnings;

use Overload::FileCheck q{:all};

mock_all_file_checks( \&my_custom_check );

use Carp;

sub my_custom_check {
    my ( $check, $f ) = @_;

    local $Carp::CarpLevel = 2;
    printf( "# %-10s called from %s", "-$check '$f'", Carp::longmess() );

    # fallback to the original Perl OP
    return FALLBACK_TO_REAL_OP;
}

-d '/root';
-l '/root';
-e '/';
-d '/';

unmock_all_file_checks();

ok 1, 'done';

done_testing;
