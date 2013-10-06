#
# This file is part of Config-Model-Tester
#
# This software is Copyright (c) 2013 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::Tester;
{
  $Config::Model::Tester::VERSION = '2.047';
}
# ABSTRACT: Test framework for Config::Model

use warnings;
use strict;
use locale;
use utf8;

use Test::More;
use Log::Log4perl 1.11 qw(:easy :levels);
use File::Path;
use File::Copy;
use File::Copy::Recursive qw(fcopy rcopy dircopy);
use File::Find;

use Path::Class 0.29;

use File::Spec ;
use Test::Warn;
use Test::Exception;
use Test::File::Contents ;
use Test::Differences;
use Test::Memory::Cycle ;

# use eval so this module does not have a "hard" dependency on Config::Model
# This way, Config::Model can build-depend on Config::Model::Tester without
# creating a build dependency loop.
eval {
    require Config::Model;
    require Config::Model::Value;
    require Config::Model::BackendMgr;
} ;

use vars qw/$model $conf_file_name $conf_dir $model_to_test $home_for_test @tests $skip @ISA @EXPORT/;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(run_tests);

$File::Copy::Recursive::DirPerms = 0755;

sub setup_test {
    my ( $model_test, $t_name, $wr_root, $setup ) = @_;

    # cleanup before tests
    $wr_root->rmtree();
    $wr_root->mkpath( { mode => 0755 } );

    my $wr_dir    = $wr_root->subdir('test-' . $t_name);
    my $wr_dir2   = $wr_root->subdir('test-' . $t_name.'-w');
    my $conf_file ;
    $conf_file = $wr_dir->file($conf_dir,$conf_file_name) if defined $conf_file_name;

    my $ex_dir = dir('t')->subdir('model_tests.d', "$model_test-examples");
    my $ex_data = -d $ex_dir->subdir($t_name)->stringify ? $ex_dir->subdir($t_name) : $ex_dir->file($t_name);
    my @file_list;
    if ($setup) {
        foreach my $file (keys %$setup) {
            my $map = $setup->{$file} ;
            my $destination_str
                = ref ($map) eq 'HASH' ? $map->{$^O} // $map->{default}
                :                        $map;
            if (not defined $destination_str) {
                die "$model_test $t_name setup error: cannot find destination for test file $file" ;
            }
            my $destination = $wr_dir->file($destination_str) ;
            $destination->parent->mkpath( { mode => 0755 }) ;
            my $data = $ex_data->file($file)->slurp() ;
            $destination->spew( $data );
            @file_list = list_test_files ($wr_dir);
        }
    }
    elsif ( $ex_data->is_dir ) {
        # copy whole dir
        my $debian_dir = $conf_dir ? $wr_dir->subdir($conf_dir) : $wr_dir ;
        $debian_dir->mkpath( { mode => 0755 });
        dircopy( $ex_data->stringify, $debian_dir->stringify )
          || die "dircopy $ex_data -> $debian_dir failed:$!";
        @file_list = list_test_files ($debian_dir);
    }
    else {

        # just copy file
        fcopy( $ex_data->stringify, $conf_file->stringify )
          || die "copy $ex_data -> $conf_file failed:$!";
    }
    ok( 1, "Copied $model_test example $t_name" );

    return ( $wr_dir, $wr_dir2, $conf_file, $ex_data, @file_list );
}

#
# New subroutine "list_test_files" extracted - Thu Nov 17 17:27:20 2011.
#
sub list_test_files {
    my $debian_dir = shift;
    my @file_list ;

	my $chop = scalar $debian_dir->dir_list();
	my $scan = sub {
		my ($child) = @_;
		return if $child->is_dir ;
		my @l = $child->components();
		splice @l,0,$chop;
		push @file_list, '/'.join('/',@l) ; # build a unix-like path even on windows
	};

	$debian_dir->recurse(callback => $scan);

    return sort @file_list;
}

sub run_model_test {
    my ($model_test, $model_test_conf, $do, $model, $trace, $wr_root) = @_ ;

    $skip = 0;
    undef $conf_file_name ;
    undef $conf_dir ;
    undef $home_for_test ;

    note("Beginning $model_test test ($model_test_conf)");

    unless ( my $return = do $model_test_conf ) {
        warn "couldn't parse $model_test_conf: $@" if $@;
        warn "couldn't do $model_test_conf: $!" unless defined $return;
        warn "couldn't run $model_test_conf" unless $return;
    }

    if ($skip) {
        note("Skipped $model_test test ($model_test_conf)");
        return;
    }

    # even undef, this resets the global variable there
    Config::Model::BackendMgr::_set_test_home($home_for_test) ;

    my $note ="$model_test uses $model_to_test model";
    $note .= " on file $conf_file_name" if defined $conf_file_name;
    note($note);

    my $idx = 0;
    foreach my $t (@tests) {
        my $t_name = $t->{name} || "t$idx";
        if ( defined $do and $do ne $t_name ) {
            $idx++;
            next;
        }
        note("Beginning subtest $model_test $t_name");

        my ($wr_dir, $wr_dir2, $conf_file, $ex_data, @file_list)
            = setup_test ($model_test, $t_name, $wr_root,$t->{setup});

        if ($t->{config_file}) {
            $wr_dir->file($t->{config_file})->parent->mkpath({mode => 0755} ) ;
        }

        my $inst = $model->instance(
            root_class_name => $model_to_test,
            root_dir        => $wr_dir->stringify,
            instance_name   => "$model_test-" . $t_name,
            config_file     => $t->{config_file} ,
            check           => $t->{load_check} || 'yes',
        );

        my $root = $inst->config_root;

        if ( exists $t->{load_warnings}
            and not defined $t->{load_warnings} )
        {
            local $Config::Model::Value::nowarning = 1;
            $root->init;
            ok( 1,"Read configuration and created instance with init() method without warning check" );
        }
        else {
            warnings_like { $root->init; } $t->{load_warnings},
                "Read configuration and created instance with init() method with warning check ";
        }

        if ( $t->{load} ) {
            print "Loading $t->{load}\n" if $trace ;
            $root->load( $t->{load} );
            ok( 1, "load called" );
        }

        if ( $t->{apply_fix} ) {
            local $Config::Model::Value::nowarning = 1;
            $inst->apply_fixes;
            ok( 1, "apply_fixes called" );
        }

        print "dumping tree ...\n" if $trace;
        my $dump  = '';
        my $risky = sub {
            $dump = $root->dump_tree( mode => 'full' );
        };

        if ( defined $t->{dump_errors} ) {
            my $nb = 0;
            my @tf = @{ $t->{dump_errors} };
            while (@tf) {
                my $qr = shift @tf;
                throws_ok { &$risky } $qr,
                  "Failed dump $nb of $model_test config tree";
                my $fix = shift @tf;
                $root->load($fix);
                ok( 1, "Fixed error nb " . $nb++ );
            }
        }

        if ( exists $t->{dump_warnings}
            and not defined $t->{dump_warnings} )
        {
            local $Config::Model::Value::nowarning = 1;
            &$risky;
            ok( 1, "Ran dump_tree (no warning check)" );
        }
        else {
            warnings_like { &$risky; } $t->{dump_warnings}, "Ran dump_tree";
        }
        ok( $dump, "Dumped $model_test config tree in full mode" );

        print $dump if $trace;

        local $Config::Model::Value::nowarning = $t->{no_warnings} || 0;

        $dump = $root->dump_tree();
        ok( $dump, "Dumped $model_test config tree in custom mode" );

        my $c = $t->{check} || {};
        my @checks = ref $c eq 'ARRAY' ? @$c
            : map { ( $_ => $c->{$_})} sort keys %$c ;
        while (@checks) {
            my $path       = shift @checks;
            my $v          = shift @checks;
            my $check_v    = ref $v ? delete $v->{value} : $v;
            my @check_args = ref $v ? %$v : ();
            my $check_str  = @check_args ? " (@check_args)" : '';
            is( $root->grab( step => $path, @check_args )->fetch(@check_args),
                $check_v, "check '$path' value$check_str" );
        }

        if (my $annot_check = $t->{verify_annotation}) {
            foreach my $path (keys %$annot_check) {
                my $note = $annot_check->{$path};
                is( $root->grab($path)->annotation,
                    $note, "check $path annotation" );
            }
        }

        $inst->write_back( force => 1 );
        ok( 1, "$model_test write back done" );

        if (my $fc = $t->{file_contents} || $t->{file_content}) {
            foreach my $f (keys %$fc) {
                my $t = $fc->{$f} ;
                my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
                foreach (@tests) {
                    file_contents_eq_or_diff $wr_dir->file($f)->stringify,  $_,
                        "check that $f contains $_";
                }
            }
        }

        if (my $fc = $t->{file_contents_like}) {
            foreach my $f (keys %$fc) {
                my $t = $fc->{$f} ;
                my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
                foreach (@tests) {
                    file_contents_like $wr_dir->file($f)->stringify,  $_,
                        "check that $f matches regexp $_";
                }
            }
        }

        if (my $fc = $t->{file_contents_unlike}) {
            foreach my $f (keys %$fc) {
                my $t = $fc->{$f} ;
                my @tests = ref $t eq 'ARRAY' ? @$t : ($t) ;
                foreach (@tests) {
                    file_contents_unlike $wr_dir->file($f)->stringify,  $_,
                        "check that $f does not match regexp $_";
                }
            }
        }

        my @new_file_list;
        if ( $ex_data->is_dir ) {

            # copy whole dir
            my $debian_dir = $conf_dir ? $wr_dir->subdir($conf_dir) : $wr_dir ;
            my @new_file_list = list_test_files($debian_dir) ;
            $t->{file_check_sub}->( \@file_list )
              if defined $t->{file_check_sub};
            eq_or_diff( \@new_file_list, [ sort @file_list ],
                "check added or removed files" );
        }

        # create another instance to read the conf file that was just written
        dircopy( $wr_dir->stringify, $wr_dir2->stringify )
          or die "can't copy from $wr_dir to $wr_dir2: $!";

        my $i2_test = $model->instance(
            root_class_name => $model_to_test,
            root_dir        => $wr_dir2->stringify,
            config_file     => $t->{config_file} ,
            instance_name   => "$model_test-$t_name-w",
        );

        ok( $i2_test, "Created instance $model_test-test-$t_name-w" );

        my $i2_root = $i2_test->config_root;
        $i2_root->init;

        my $p2_dump = $i2_root->dump_tree();
        ok( $dump, "Dumped $model_test 2nd config tree in custom mode" );

        eq_or_diff( $p2_dump, $dump,
            "compare original $model_test custom data with 2nd instance custom data"
        );

        ok( -s "$wr_dir2/$conf_dir/$conf_file_name" ,
            "check that original $model_test file was not clobbered" )
                if defined $conf_file_name ;

        my $wr_check = $t->{wr_check} || {};
        foreach my $path ( sort keys %$wr_check ) {
            my $v          = $wr_check->{$path};
            my $check_v    = ref $v ? delete $v->{value} : $v;
            my @check_args = ref $v ? %$v : ();
            is( $i2_root->grab( step => $path, @check_args )->fetch(@check_args),
                $check_v, "wr_check $path value (@check_args)" );
        }

        note("End of subtest $model_test $t_name");

        $idx++;
    }
    note("End of $model_test test");

}

sub run_tests {
    my ( $arg, $test_only_model, $do ) = @_;

    my ( $log, $show ) = (0) x 2;

    my $trace = ($arg =~ /t/) ? 1 : 0;
    $log  = 1 if $arg =~ /l/;
    $show = 1 if $arg =~ /s/;

    my $log4perl_user_conf_file = ($ENV{HOME} || '') . '/.log4config-model';

    if ( $log and -e $log4perl_user_conf_file ) {
        Log::Log4perl::init($log4perl_user_conf_file);
    }
    else {
        Log::Log4perl->easy_init( $log ? $WARN : $ERROR );
    }

    eval { $model = Config::Model->new(); } ;
    if ($@) {
        plan skip_all => 'Config::Model is not loaded' ;
        return;
    }

    Config::Model::Exception::Any->Trace(1) if $arg =~ /e/;

    ok( 1, "compiled" );

    # pseudo root where config files are written by config-model
    my $wr_root = dir('wr_root');

    my @group_of_tests = grep { /-test-conf.pl$/ } glob("t/model_tests.d/*");

    foreach my $model_test_conf (@group_of_tests) {
        my ($model_test) = ( $model_test_conf =~ m!\.d/([\w\-]+)-test-conf! );
        next if ( $test_only_model and $test_only_model ne $model_test ) ;
        run_model_test($model_test, $model_test_conf, $do, $model, $trace, $wr_root) ;
    }

    memory_cycle_ok($model,"test memory cycle") ;

    done_testing;

}
1;

__END__

=pod

=head1 NAME

Config::Model::Tester - Test framework for Config::Model

=head1 VERSION

version 2.047

=head1 SYNOPSIS

 # in t/model_test.t
 use warnings;
 use strict;

 use Config::Model::Tester ;
 use ExtUtils::testlib;

 my $arg = shift || '';
 my $test_only_model = shift || '';
 my $do = shift ;

 run_tests($arg, $test_only_model, $do) ;

=head1 DESCRIPTION

This class provides a way to test configuration models with tests files.
This class was designed to tests several models and several tests
cases per model.

A specific layout for test files must be followed

=head2 Simple test file layout

 t
 |-- model_test.t
 \-- model_tests.d
     |-- lcdd-test-conf.pl   # test specification
     \-- lcdd-examples
         |-- t0              # test case t0
         \-- LCDD-0.5.5      # test case for older LCDproc

In the example above, we have 1 model to test: C<lcdd> and 2 tests
cases.

Test specification is written in C<lcdd-test-conf.pl> file. Test
cases are plain files in C<lcdd-examples>. C<lcdd-test-conf.pl> will
contain instructions so that each file will be used as a
C</etc/LCDd.conf> file during each test case.

C<lcdd-test-conf.pl> can contain specifications for more test
case. Each test case will require a new file in C<lcdd-examples>
directory.

See L</Examples> for a link to the actual LCDproc model tests

=head2 Test file layout for multi-file configuration

When a configuration is spread over several files, test examples must be
provided in sub-directories:

 t/model_tests.d
 \-- dpkg-test-conf.pl         # test specification
 \-- dpkg-examples
     \-- libversion            # example subdir
         \-- debian            # directory for one test case
             |-- changelog
             |-- compat
             |-- control
             |-- copyright
             |-- rules
             |-- source
             |   \-- format
             \-- watch

In the example above, the test specification is written in
C<dpkg-test-conf.pl>. Dpkg layout requires several files per test case.
C<dpkg-test-conf.pl> will contain instruction so that each directory
under C<dpkg-examples> will be used.

See L</Examples> for a link to the (many) Dpkg model tests

=head2 Test file layout depending on system

 t/model_tests.d/
 |-- ssh-test-conf.pl
 |-- ssh-examples
     \-- basic
         |-- system_ssh_config
         \-- user_ssh_config

In this example, the layout of the configuration files depend on the
system. For instance, system wide C<ssh_config> is stored in C</etc/ssh> on
Linux, and directly in C</etc> on MacOS.

L<ssh-test-conf.pl|https://github.com/dod38fr/config-model-openssh/blob/master/t/model_tests.d/ssh-test-conf.pl>
will specify the target path of each file. I.e.:

 $home_for_test = $^O eq 'darwin' ? '/Users/joe'
                :                   '/home/joe' ;

 # ...

      setup => {
        'system_ssh_config' => {
            'darwin' => '/etc/ssh_config',
            'default' => '/etc/ssh/ssh_config',
        },
        'user_ssh_config' => "$home_for_test/.ssh/config"

See the actual L<Ssh and Sshd model tests|https://github.com/dod38fr/config-model-openssh/tree/master/t/model_tests.d>

=head2 Basic test specification

Each model test is specified in C<< <model>-test-conf.pl >>. This file
contains a set of global variable. (yes, global variables are often bad ideas
in programs, but they are handy for tests):

 # config file name (used to copy test case into test wr_root directory)
 $conf_file_name = "fstab" ;
 # config dir where to copy the file
 #$conf_dir = "etc" ;
 # home directory for this test
 $home_for_test = '/home/joe' ;

Here, C<t0> file will be copied in C<wr_root/test-t0/etc/fstab>.

 # config model name to test
 $model_to_test = "Fstab" ;

 # list of tests
 @tests = (
    {
     # test name
     name => 't0',
     # add optional specification here for t0 test
    },
    {
     name => 't1',
     # add optional specification here for t1 test
     },
 );

 1; # to keep Perl happy

See actual L<fstab test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/fstab-test-conf.pl>.

=head2 Internal tests

Some tests will require the creation of a configuration class dedicated
for test. This test class can be created directly in the test specification
by calling L<create_config_class|Config::Model/create_config_class> on
C<$model> variable. See for instance the
L<layer test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/layer-test-conf.pl>
or the
L<test for shellvar backend|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/backend-shellvar-test-conf.pl>.

=head2 Test specification with arbitrary file names

In some models (e.g. C<Multistrap>, the config file is chosen by the user.
In this case, the file name must be specified for each tests case:

 $model_to_test = "Multistrap";

 @tests = (
    {
        name        => 'arm',
        config_file => '/home/foo/my_arm.conf',
        check       => {},
    },
 );

See actual L<multistrap test|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/multistrap-test-conf.pl>.

=head2 Test scenario

Each subtest follow a sequence explained below. Each step of this
sequence may be altered by adding specification in the test case:

=over

=item *

Setup test in C<< wr_root/<subtest name>/ >>. If your configuration file layout depend
on the target system, you will have to specify the path using C<setup> parameter:

 setup => {
    'file_name_in_examples_dir' => {
        'darwin' => '/etc/foo', # macosx
        'default' => '/etc/bar' # others
    },
    'another_file_in_examples_dir' => $computed_path
 }

=item *

Create configuration instance, load config data and check its validity. Use
C<< load_check => 'no' >> if your file is not valid.

=item *

Check for config data warning. You should pass the list of expected warnings.
E.g.

    load_warnings => [ qr/Missing/, (qr/deprecated/) x 3 , ],

Use an empty array_ref to masks load warnings.

=item *

Optionally load configuration data. You should design this config data to
suppress any error or warning mentioned above. E.g:

    load => 'binary:seaview Synopsis="multiplatform interface for sequence alignment"',

=item *

Optionally, call L<apply_fixes|Config::Model::Instance/apply_fixes>:

    apply_fix => 1,

=item *

Call L<dump_tree|Config::Model::Node/dump_tree ( ... )> to check the validity of the
data. Use C<dump_errors> if you expect issues:

    dump_errors =>  [
        # the issues     the fix that will be applied
        qr/mandatory/ => 'Files:"*" Copyright:0="(c) foobar"',
        qr/mandatory/ => ' License:FOO text="foo bar" ! Files:"*" License short_name="FOO" '
    ],

=item *

Likewise, specify any expected warnings (note the list must contain only C<qr> stuff):

        dump_warnings => [ (qr/deprecated/) x 3 ],

You can tolerate any dump warning this way:

        dump_warnings => undef ,

=item *

Run specific content check to verify that configuration data was retrieved
correctly:

    check => [
        'fs:/proc fs_spec',           "proc" ,
        'fs:/proc fs_file',           "/proc" ,
        'fs:/home fs_file',          "/home",
    ],

You can run check using different check modes (See L<Config::Model::Value/"fetch( ... )">)
by passing a hash ref instead of a scalar :

    check  => [
        'sections:debian packages:0' , { qw/mode layered value dpkg-dev/},
        ''sections:base packages:0',   { qw/mode layered value gcc-4.2-base/},
    ],

The whole hash content (except "value") is passed to  L<grab|Config::Model::AnyThing/"grab(...)">
and L<fetch|Config::Model::Value/"fetch( ... )">

=item *

Verify annotation extracted from the configuration file comments:

    verify_annotation => {
            'source Build-Depends' => "do NOT add libgtk2-perl to build-deps (see bug #554704)",
            'source Maintainer' => "what a fine\nteam this one is",
        },

=item *

Write back the config data in C<< wr_root/<subtest name>/ >>.
Note that write back is forced, so the tested configuration files are
written back even if the configuration values were not changed during the test.

You can skip warning when writing back with:

    no_warnings => 1,

=item *

Check the content of the written files(s) with L<Test::File::Contents>. Tests can be grouped
in an array ref:

   file_contents => {
            "/home/foo/my_arm.conf" => "really big string" ,
            "/home/bar/my_arm.conf" => [ "really big string" , "another"], ,
        }

   file_contents_like => {
            "/home/foo/my_arm.conf" => [ qr/should be there/, qr/as well/ ] ,
   }

   file_contents_unlike => {
            "/home/foo/my_arm.conf" => qr/should NOT be there/ ,
   }

=item *

Check added or removed configuration files. If you expect changes,
specify a subref to alter the file list:

    file_check_sub => sub {
        my $list_ref = shift ;
        # file added during tests
        push @$list_ref, "/debian/source/format" ;
    };

=item *

Copy all config data from C<< wr_root/<subtest name>/ >>
to C<< wr_root/<subtest name>-w/ >>. This steps is necessary
to check that configuration written back has the same content as
the original configuration.

=item *

Create another configuration instance to read the conf file that was just copied
(configuration data is checked.)

=item *

Compare data read from original data.

=item *

Run specific content check on the B<written> config file to verify that
configuration data was written and retrieved correctly:

    wr_check => {
        'fs:/proc fs_spec',           "proc" ,
        'fs:/proc fs_file',           "/proc" ,
        'fs:/home fs_file',          "/home",
    },

Like the C<check> item explained above, you can run C<wr_check> using
different check modes.

=back

=head2 running the test

Run all tests:

 prove -l t/model_test.t

By default, all tests are run on all models.

You can pass arguments to C<t/model_test.t>:

=over

=item *

a bunch of letters. 't' to get test traces. 'e' to get stack trace in case of
errors, 'l' to have logs. All other letters are ignored. E.g.

  # run with log and error traces
  prove -lv t/model_test.t :: el

=item *

The model name to tests. E.g.:

  # run only fstab tests
  prove -lv t/model_test.t :: x fstab

=item *

The required subtest E.g.:

  # run only fstab tests t0
  prove -lv t/model_test.t :: x fstab t0

=back

=head1 Examples

=over

=item *

L<LCDproc|http://lcdproc.org> has a single configuration file:
C</etc/LCDd.conf>. Here's LCDproc test
L<layout|https://github.com/dod38fr/config-model-lcdproc/tree/master/t/model_tests.d>
and the L<test specification|https://github.com/dod38fr/config-model-lcdproc/blob/master/t/model_tests.d/lcdd-test-conf.pl>

=item *

Dpkg packages are constructed from several files. These files are handled like
configuration files by L<Config::Model::Dpkg>. The
L<test layout|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=tree;f=t/model_tests.d;hb=HEAD>
features test with multiple file in
L<dpkg-examples|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=tree;f=t/model_tests.d/dpkg-examples;hb=HEAD>.
The test is specified in L<dpkg-test-conf.pl|http://anonscm.debian.org/gitweb/?p=pkg-perl/packages/libconfig-model-dpkg-perl.git;a=blob_plain;f=t/model_tests.d/dpkg-test-conf.pl;hb=HEAD>

=item *

L<multistrap-test-conf.pl|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/multistrap-test-conf.pl>
amd L<multistrap-examples|https://github.com/dod38fr/config-model/tree/master/t/model_tests.d/multistrap-examples>
specify a test where the configuration file name is not imposed by the
application. The file name must then be set in the test specification.

=item *

L<backend-shellvar-test-conf.pl|https://github.com/dod38fr/config-model/blob/master/t/model_tests.d/backend-shellvar-test-conf.pl>
is a more complex example showing how to test a backend. The test is done creating a dummy model within the test specification.

=back

=head1 SEE ALSO

=over 4

=item *

L<Config::Model>

=item *

L<Test::More>

=back

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Websites

The following websites have more information about this module, and may be of help to you. As always,
in addition to those websites please use your favorite search engine to discover more resources.

=over 4

=item *

MetaCPAN

A modern, open-source CPAN search engine, useful to view POD in HTML format.

L<http://metacpan.org/release/Config-Model-Tester>

=item *

Search CPAN

The default CPAN search engine, useful to view POD in HTML format.

L<http://search.cpan.org/dist/Config-Model-Tester>

=item *

RT: CPAN's Bug Tracker

The RT ( Request Tracker ) website is the default bug/issue tracking system for CPAN.

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Config-Model-Tester>

=item *

AnnoCPAN

The AnnoCPAN is a website that allows community annotations of Perl module documentation.

L<http://annocpan.org/dist/Config-Model-Tester>

=item *

CPAN Ratings

The CPAN Ratings is a website that allows community ratings and reviews of Perl modules.

L<http://cpanratings.perl.org/d/Config-Model-Tester>

=item *

CPAN Forum

The CPAN Forum is a web forum for discussing Perl modules.

L<http://cpanforum.com/dist/Config-Model-Tester>

=item *

CPANTS

The CPANTS is a website that analyzes the Kwalitee ( code metrics ) of a distribution.

L<http://cpants.perl.org/dist/overview/Config-Model-Tester>

=item *

CPAN Testers

The CPAN Testers is a network of smokers who run automated tests on uploaded CPAN distributions.

L<http://www.cpantesters.org/distro/C/Config-Model-Tester>

=item *

CPAN Testers Matrix

The CPAN Testers Matrix is a website that provides a visual overview of the test results for a distribution on various Perls/platforms.

L<http://matrix.cpantesters.org/?dist=Config-Model-Tester>

=item *

CPAN Testers Dependencies

The CPAN Testers Dependencies is a website that shows a chart of the test results of all dependencies for a distribution.

L<http://deps.cpantesters.org/?module=Config::Model::Tester>

=back

=head2 Bugs / Feature Requests

Please report any bugs or feature requests by email to C<bug-config-model-tester at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Config-Model-Tester>. You will be automatically notified of any
progress on the request by the system.

=head2 Source Code

The code is open to the world, and available for you to hack on. Please feel free to browse it and play
with it, or whatever. If you want to contribute patches, please send me a diff or prod me to pull
from your repository :)

L<http://github.com/dod38fr/config-model-tester.git>

  git clone git://github.com/dod38fr/config-model-tester.git

=cut
