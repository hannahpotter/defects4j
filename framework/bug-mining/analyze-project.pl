#!/usr/bin/env perl
#
#-------------------------------------------------------------------------------
# Copyright (c) 2014-2024 René Just, Darioush Jalali, and Defects4J contributors.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#-------------------------------------------------------------------------------

=pod

=head1 NAME

analyze-project.pl -- Determine all suitable candidates listed in the active-bugs csv.

=head1 SYNOPSIS

analyze-project.pl -p project_id -w work_dir -g tracker_name -t tracker_project_id [-b bug_id] [-D]

=head1 OPTIONS

=over 4

=item B<-p C<project_id>>

The id of the project for which the version pairs are analyzed.

=item B<-w C<work_dir>>

The working directory used for the bug-mining process.

=item B<-g C<tracker_name>>

The source control tracker name, e.g., jira, github, google, or sourceforge.

=item B<-t C<tracker_project_id>>

The name used on the issue tracker to identify the project. Note that this might
not be the same as the Defects4j project name / id, for instance, for the
commons-lang project is LANG.

=item B<-b C<bug_id>>

Only analyze this bug id. The bug_id has to follow the format B<(\d+)(:(\d+))?>.
By default all bug ids, listed in the active-bugs csv, are considered.

=item B<-D>

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=back

=head1 DESCRIPTION

Runs the following worflow for all candidate bugs in the project's C<active-bugs.csv>,
or (if -b is specified) for a subset of candidates:

=over 4

=item 1) Verify that src diff (between pre-fix and post-fix) is not empty.

=item 3) Checkout fixed revision.

=item 4) Compile src and test.

=item 5) Run tests and log failing tests to F<C<PROJECTS_DIR>/<PID>/failing_tests>.

=item 6) Exclude failing tests, recompile and rerun. This is repeated until
         there are no more failing tests in F<$TEST_RUNS> consecutive
         executions. (Maximum limit of looping in this phase is specified by
         F<$MAX_TEST_RUNS>).

=item 7) Checkout fixed version.

=item 8) Apply src patch (fixed -> buggy).

=item 9) Compile src and test.

=back

The result for each individual step is stored in F<C<work_dir>/$TAB_REV_PAIRS>.
For each steps the output table contains a column, indicating the result of the
the step or '-' if the step was not applicable.

=cut
use warnings;
use strict;
use File::Basename;
use Cwd qw(abs_path);
use Getopt::Std;
use Pod::Usage;
use Carp qw(confess);

use lib (dirname(abs_path(__FILE__)) . "/../core/");
use Constants;
use Project;
use DB;
use Utils;

my %cmd_opts;
getopts('p:w:g:t:b:D', \%cmd_opts) or pod2usage(1);

pod2usage(1) unless defined $cmd_opts{p} and defined $cmd_opts{w}
                    and defined $cmd_opts{g} and defined $cmd_opts{t};

my $PID = $cmd_opts{p};
my $BID = $cmd_opts{b};
my $WORK_DIR = abs_path($cmd_opts{w});
my $TRACKER_ID = $cmd_opts{t};
my $TRACKER_NAME = $cmd_opts{g};
$DEBUG = 1 if defined $cmd_opts{D};

# Keep list of errors so user can see and resolve all at once
my @errors = ();

# Check format of target version id
if (defined $BID) {
    $BID =~ /^(\d+)(:(\d+))?$/ or die "Wrong version id format ((\\d+)(:(\\d+))?): $BID!";
}

# Add script and core directory to @INC
unshift(@INC, "$WORK_DIR/framework/core");

# Override global constants
$REPO_DIR = "$WORK_DIR/project_repos";
$PROJECTS_DIR = "$WORK_DIR/framework/projects";

# Set the projects and repository directories to the current working directory
my $PATCHES_DIR = "$PROJECTS_DIR/$PID/patches";
my $FAILING_DIR = "$PROJECTS_DIR/$PID/failing_tests";

my $SCRIPTS = "$WORK_DIR/../../../scripts";
my $DEPENDENCIES = "$PROJECTS_DIR/$PID/lib/dependency";
my $ANALYZER_OUTPUT = "$PROJECTS_DIR/$PID/analyzer_output";
my $ARGS_FILES = "$PROJECTS_DIR/$PID/args_files";
system("mkdir -p $ARGS_FILES");

-d $PATCHES_DIR or die "$PATCHES_DIR does not exist: $!";
-d $FAILING_DIR or die "$FAILING_DIR does not exist: $!";

# DB_CSVs directory
my $db_dir = $WORK_DIR;

# Number of successful test runs in a row required
my $TEST_RUNS = 2;
# Number of maximum test runs (give up point)
my $MAX_TEST_RUNS = 10;

# Temporary directory
my $TMP_DIR = Utils::get_tmp_dir();
system("mkdir -p $TMP_DIR");

# Set up project
my $project = Project::create_project($PID);
$project->{prog_root} = $TMP_DIR;

# Get database handle for results
my $dbh = DB::get_db_handle($TAB_REV_PAIRS, $db_dir);
my @COLS = DB::get_tab_columns($TAB_REV_PAIRS) or die;

# Figure out which IDs to run script for
my @ids = $project->get_bug_ids();
if (defined $BID) {
    if ($BID =~ /(\d+):(\d+)/) {
        @ids = grep { ($1 <= $_) && ($_ <= $2) } @ids;
    } else {
        # single vid
        @ids = grep { ($BID == $_) } @ids;
    }
}

my $sth = $dbh->prepare("SELECT * FROM $TAB_REV_PAIRS WHERE $PROJECT=? AND $ID=?") or die $dbh->errstr;
foreach my $bid (@ids) {
    printf ("%4d: $project->{prog_name}\n", $bid);

    # Skip existing entries
    $sth->execute($PID, $bid);
    if ($sth->rows !=0) {
        printf("      -> Skipping (existing entry in $TAB_REV_PAIRS)\n");
        next;
    }

    my %data;
    $data{$PROJECT} = $PID;
    $data{$ID} = $bid;
    $data{$ISSUE_TRACKER_NAME} = $TRACKER_NAME;
    $data{$ISSUE_TRACKER_ID} = $TRACKER_ID;

    _check_diff($project, $bid, \%data) and
    _check_compilation($project, $bid, \%data) or next;# and
    _export_tests($project, $bid, \%data) or next;
    #_check_t2v2($project, $bid, \%data) and
    #_check_t2v1($project, $bid, \%data) or next;

    # Add data set to result file
    _add_row(\%data);
}
$dbh->disconnect();
system("rm -rf $TMP_DIR") unless $DEBUG;

#
# Check size of src diff, which is created by initialize-revisions.pl script,
# for a given candidate bug (bid).
#
# Returns 1 on success, 0 otherwise
#
sub _check_diff {
    my ($project, $bid, $data) = @_;

    # Determine patch size for src and test patches (rev2 -> rev1)
    my $patch_test = "$PATCHES_DIR/$bid.test.patch";
    my $patch_src = "$PATCHES_DIR/$bid.src.patch";

    if (!(-e $patch_test) || (-z $patch_test)) {
        $data->{$DIFF_TEST} = 0;
    } else {
        my $diff = _read_file($patch_test);
        die unless defined $diff;
        $data->{$DIFF_TEST} = scalar(split("\n", $diff));
    }

    if (-z $patch_src) {
        $data->{$DIFF_SRC} = 0;
        return 0;
    } else {
        my $diff = _read_file($patch_src);
        die unless defined $diff;
        $data->{$DIFF_SRC} = scalar(split("\n", $diff)) or return 0;
    }

    return 1;
}

#
# Check whether v1, v2, and t2 can be compiled and export args for javac.
#
# Returns 1 on success, 0 otherwise
#
sub _check_compilation {
    my ($project, $bid, $data) = @_;

    # Lookup revision ids
    my $v1  = $project->lookup("${bid}b");
    my $v2  = $project->lookup("${bid}f");

    my $project_path = $project->{prog_root};

    # Checkout v1
    $project->checkout_vid("${bid}b", $TMP_DIR, 1) == 1 or die;

    # PAUSE PLACE TODO make reliable way to set the compiler source and target to Java 11
    # Also in previous phase check that source and test Directories are being found correctly (looks like needs change to like DBUtils.pm _maven_2_layout)
    # Also replace the classpath paths in the previous phase with command line arg placeholder

    # TODO the error log isn't working...

    # Check that the v1 and t2 compile with maven
    my $check_compile = "cd $project_path && mvn compile";
    my $log;
    my $ret = Utils::exec_cmd($check_compile, "Checking that v1 source compiles with maven.", \$log);
    if (! $ret) {
        push(@errors, "--------------------- Error compiling source v1 for bug ${bid} --------------------- \n${log}");
    }
    _add_bool_result($data, $COMP_V1, $ret) or return 0;
    # TODO Find more general way to fix the animal sniffer and version plugin bundle
    my $check_test_compile = "cd $project_path && mvn test-compile -Danimal.sniffer.skip=true";
    $ret = Utils::exec_cmd($check_test_compile, "Checking that v1t2 compiles with maven.", \$log);
    if (! $ret) {
        push(@errors, "--------------------- Error compiling tests v1t2 for bug ${bid} --------------------- \n${log}");
    }
    _add_bool_result($data, $COMP_T2V1, $ret) or return 0;

    # Construct the args files for compiling source and tests
    system("mkdir -p $ARGS_FILES/$bid");
    my $v1_layout = $project->_determine_layout($v1);
    # TODO can jsut call $project->src_dir(vid) to get the path to the source files
    my $construct_args = "python3 $SCRIPTS/construct_javac_args.py"
                         ." --dependency $ANALYZER_OUTPUT/$bid/source_cp"
                         ." --projectpath $project_path"
                         ." --output $ARGS_FILES/$bid/args_source_v1.txt"
                         ." --classpath target/classes"
                         ." --sourcepath $v1_layout->{src}"
                         ." --sourcefiles $project_path/$v1_layout->{src}"
                         ." --target target/classes";
    Utils::exec_cmd($construct_args, "Constructing args file for compiling v1 source.");
    my $v2_layout = $project->_determine_layout($v2);
    $construct_args = "python3 $SCRIPTS/construct_javac_args.py"
                         ." --dependency $ANALYZER_OUTPUT/$bid/test_cp"
                         ." --projectpath $project_path"
                         ." --output $ARGS_FILES/$bid/args_test_v2.txt"
                         .' --classpath target/classes'
                         ." --sourcepath $v1_layout->{test}"
                         ." --sourcefiles $project_path/$v1_layout->{test}"
                         .' --target target/test-classes';
    Utils::exec_cmd($construct_args, "Constructing args file for compiling v2 tests.");
    
    # Checkout v2
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) == 1 or die;

    # Check that the v2 and t2 compile with maven
    $check_compile = "cd $project_path && mvn compile";
    $ret = Utils::exec_cmd($check_compile, "Checking that v2 source compiles with maven.", \$log);
    if (! $ret) {
        push(@errors, "--------------------- Error compiling source v2 for bug ${bid} --------------------- \n${log}");
    }
    _add_bool_result($data, $COMP_V2, $ret) or return 0;

    # Construct the args files for compiling source
    $construct_args = "python3 $SCRIPTS/construct_javac_args.py"
                         ." --dependency $ANALYZER_OUTPUT/$bid/source_cp"
                         ." --projectpath $project_path"
                         ." --output $ARGS_FILES/$bid/args_source_v2.txt"
                         .' --classpath target/classes'
                         ." --sourcepath $v2_layout->{test}"
                         ." --sourcefiles $project_path/$v2_layout->{test}"
                         .' --target target/classes';
    Utils::exec_cmd($construct_args, "Constructing args file for compiling v2 source.");
}

#
# Export failing tests in v2t2 to exclude.
#
# Returns 1 on success, 0 otherwise
#
sub _export_tests {
    my ($project, $bid, $data) = @_;

    my $project_path = $project->{prog_root};

    # Lookup revision ids
    my $v1 = $project->lookup("${bid}b");
    my $v2 = $project->lookup("${bid}f");

    # Clean previous results
    `>$FAILING_DIR/$v2` if -e "$FAILING_DIR/$v2";

    # Checkout v2
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) == 1 or die;

    # https://stackoverflow.com/questions/9288107/run-single-test-from-a-junit-class-using-command-line
    # Run a java test class
    #    java -jar junit-platform-console-standalone-1.11.3.jar execute -cp <classpath-for-the-class-under-test> --select-class=hello.HelloTest
    # Run a java test method
    #    java -jar junit-platform-console-standalone-1.11.3.jar execute -cp <classpath-for-the-class-under-test> --select=method:hello.HelloTest#hi


    # Run tests with maven first
    # Animal sniffer is incompatible with Java 11 (the --release flag in javac does the same functionality)
    # Jacoco is for instrumenting class files to get code coverage reports
    my $run_tests = "cd $project_path && mvn test -Danimal.sniffer.skip=true -Djacoco.skip=true";
    my $log;
    my $ret = Utils::exec_cmd($run_tests, "Running v2 tests with maven.", \$log);
    if (! $ret) {
        push(@errors, "--------------------- Error running tests for bug ${bid} --------------------- \n${log}");
        return 0;
    }
    # Extract test info to run natively
    system("mkdir -p $ARGS_FILES/$bid/test_info");
    my $construct_args = "python3 $SCRIPTS/extract_test_info.py"
                         ." --dependency $ANALYZER_OUTPUT/$bid/test_cp"
                         ." --reports $project_path/target/surefire-reports"
                         ." --output $ARGS_FILES/$bid/test_info"
                         ." --classes $project_path/target/classes"
                         ." --testclasses $project_path/target/test-classes";
    Utils::exec_cmd($construct_args, "Extracting test info for t2.");

    my $successful_runs = 0;
    my $run = 20; # TEMP TO SKIP
    while ($successful_runs < $TEST_RUNS && $run <= $MAX_TEST_RUNS) {
        # Automatically fix broken tests and recompile
        $project->fix_tests("${bid}f");
        $project->compile("$ARGS_FILES/$bid/args_test_v2.txt", "TODELETE.txt") or die;

        # Run t2 and get number of failing tests
        my $file = "$project->{prog_root}/v2.fail"; `>$file`;

        $project->run_tests($file) or die;
	
        # Get number of failing tests
        #my $list = Utils::get_failing_tests($file);
        #my $fail = scalar(@{$list->{"classes"}}) + scalar(@{$list->{"methods"}});
    my $fail = 0;
        #if ($run == 1) {
        #    $data->{$FAIL_T2V2} = $fail;
        #} else {
        #    $data->{$FAIL_T2V2} += $fail;
        #}

        ++$successful_runs;

        # Append to log if there were (new) failing tests
        unless ($fail == 0) {
            open(OUT, ">>$FAILING_DIR/$v2") or die "Cannot write failing tests: $!";
            print OUT "## $project->{prog_name}: $v2 ##\n";
            close OUT;
            system("cat $file >> $FAILING_DIR/$v2");
            $successful_runs = 0;
        }

        ++$run;
    }
    return 1;
}

#
# Read a file line by line and return an array with all lines.
#
sub _read_file {
    my $fn = shift;
    open(FH, "<$fn") or confess "Could not open file: $!";
    my @lines = <FH>;
    close(FH);
    return join('', @lines);
}

#
# Insert boolean success into hash
#
sub _add_bool_result {
    my ($data, $key, $success) = @_;
    $data->{$key} = $success;
}

#
# Add a row to the database table
#
sub _add_row {
    my $data = shift;

    my @tmp;
    foreach (@COLS) {
        push (@tmp, $dbh->quote((defined $data->{$_} ? $data->{$_} : "-")));
    }

    my $row = join(",", @tmp);
    $dbh->do("INSERT INTO $TAB_REV_PAIRS VALUES ($row)");
}

=pod

=head1 SEE ALSO

Previous step in workflow: Manually verify that all test failures
(failing_tests) are valid and not spurious, broken, random, or due to classpath
issues.

Next step in workflow: F<get-trigger.pl>.

=cut
