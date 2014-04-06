
use strict;
use warnings;
use Test::More;
use Test::Import;

does_import_strict 'Curator::Base';
does_import_warnings 'Curator::Base';
does_import_feature 'Curator::Base', 'say';

done_testing;
