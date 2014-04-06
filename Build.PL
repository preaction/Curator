
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Module::Build" => "0.3601"
  },
  "configure_requires" => {
    "ExtUtils::MakeMaker" => "6.30",
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "System for managing a media library",
  "dist_author" => [
    "Doug Bell <preaction\@cpan.org>"
  ],
  "dist_name" => "Curator",
  "dist_version" => "0.001",
  "license" => "perl",
  "module_name" => "Curator",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "Data::UUID" => "1.218",
    "Import::Into" => 0,
    "Module::Runtime" => 0,
    "Moo" => 0,
    "MooX::Types::MooseLike" => 0,
    "perl" => "5.10"
  },
  "script_files" => [
    "bin/epub.pl",
    "bin/extract.pl",
    "bin/fill_meta.pl",
    "bin/rip.pl"
  ],
  "test_requires" => {
    "Test::Compile" => 0,
    "Test::Import" => 0,
    "Test::Most" => 0
  }
);


unless ( eval { Module::Build->VERSION(0.4004) } ) {
  my $tr = delete $module_build_args{test_requires};
  my $br = $module_build_args{build_requires};
  for my $mod ( keys %$tr ) {
    if ( exists $br->{$mod} ) {
      $br->{$mod} = $tr->{$mod} if $tr->{$mod} > $br->{$mod};
    }
    else {
      $br->{$mod} = $tr->{$mod};
    }
  }
}

my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
