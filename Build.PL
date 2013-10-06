
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Module::Build" => "0.3601"
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Test framework for Config::Model",
  "dist_author" => [
    "Dominique Dumont"
  ],
  "dist_name" => "Config-Model-Tester",
  "dist_version" => "2.047",
  "license" => "lgpl",
  "module_name" => "Config::Model::Tester",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "File::Copy" => 0,
    "File::Copy::Recursive" => 0,
    "File::Find" => 0,
    "File::Path" => 0,
    "File::Spec" => 0,
    "Log::Log4perl" => "1.11",
    "Path::Class" => "0.29",
    "Test::Differences" => 0,
    "Test::Exception" => 0,
    "Test::File::Contents" => 0,
    "Test::Memory::Cycle" => 0,
    "Test::More" => 0,
    "Test::Warn" => 0,
    "perl" => "5.010"
  },
  "script_files" => [],
  "test_requires" => {}
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
