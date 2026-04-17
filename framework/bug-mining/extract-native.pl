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

extract-native.pl -- Extract the metadata needed to compile and run candidate bugs using javac and junit

=head1 SYNOPSIS

extract-native.pl -p project_id -w work_dir [-b bug_id] [-D]

=head1 OPTIONS

=over 4

=item B<-p C<project_id>>

The id of the project for which the version pairs are analyzed.

=item B<-w C<work_dir>>

The working directory used for the bug-mining process.

=item B<-b C<bug_id>>

Only analyze this bug id. The bug_id has to follow the format B<(\d+)(:(\d+))?>.
By default all bug ids that compile and whose tests do not have errors running, listed in F<C<work_dir>/$TAB_REV_PAIRS>, are considered.

=item B<-D>

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=back

=head1 DESCRIPTION

Runs the following worflow for all suitable candidate bugs listed in F<C<work_dir>/$TAB_REV_PAIRS>,
or (if -b is specified) for a subset of candidates:

=over 4

=item 1) Checkout buggy version

=item 2) Compile source and tests

=item 3) Checkout fixed version

=item 4) Compile source and tests

=item 5) Run tests and confirm that the result is the same using JUnit as running with the build system. 
         There should be no failing tests and the same number of tests should be run.

=back

The result for each individual step is stored in F<C<work_dir>/$TAB_NATIVE>.
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
getopts('p:w:b:D', \%cmd_opts) or pod2usage(1);

pod2usage(1) unless defined $cmd_opts{p} and defined $cmd_opts{w};

my $PID = $cmd_opts{p};
my $BID = $cmd_opts{b};
my $WORK_DIR = abs_path($cmd_opts{w});
my $TEST_JAR = (dirname(abs_path(__FILE__)) . "/../projects/lib");
$DEBUG = 1 if defined $cmd_opts{D};

# Check format of target version id
if (defined $BID) {
    $BID =~ /^(\d+)(:(\d+))?$/ or die "Wrong version id format ((\\d+)(:(\\d+))?): $BID!";
}

# Add script and core directory to @INC
unshift(@INC, "$WORK_DIR/framework/core");

# Override global constants
$REPO_DIR = "$WORK_DIR/project_repos";
$PROJECTS_DIR = "$WORK_DIR/framework/projects";

my $ANALYZER_OUTPUT = "$PROJECTS_DIR/$PID/analyzer_output";
my $BUILD_ARGS = "$PROJECTS_DIR/$PID/build_args";
my $PREEXEC_CMDS = "$PROJECTS_DIR/$PID/preexec_cmds";
my $JUNIT_ARGS = "$PROJECTS_DIR/$PID/junit_args";
my $ALL_TESTSUITES = "$PROJECTS_DIR/$PID/all_testsuites";
my $ALL_TESTCASES = "$PROJECTS_DIR/$PID/all_testcases";
system("mkdir -p $BUILD_ARGS");
system("mkdir -p $PREEXEC_CMDS");
system("mkdir -p $JUNIT_ARGS");
system("mkdir -p $ALL_TESTSUITES");
system("mkdir -p $ALL_TESTCASES");

# Keep log of issues
my $LOG = "$PROJECTS_DIR/$PID/extract_native_error_log.txt";

# DB_CSVs directory
my $db_dir = $WORK_DIR;

# Temporary directory
my $TMP_DIR = Utils::get_tmp_dir();
system("mkdir -p $TMP_DIR");

# Set up project
my $project = Project::create_project($PID);
$project->{prog_root} = $TMP_DIR;

# Get database handle for results
my $dbh_revs = DB::get_db_handle($TAB_REV_PAIRS, $db_dir);
my $dbh_native = DB::get_db_handle($TAB_NATIVE, $db_dir);
my @COLS = DB::get_tab_columns($TAB_NATIVE) or die;

# Clean up previous log files
system("rm -f $LOG");
my @bids = _get_bug_ids($BID);
foreach my $bid (@bids) {
    printf ("%4d: $project->{prog_name}\n", $bid);

    # Keep track of revision data
    my %data;
    $data{$PROJECT} = $PID;
    $data{$ID} = $bid;

    _check_compilation($project, $bid, \%data) and
    _check_tests($project, $bid, \%data);

    # Add data set to result file
    _add_rows(\%data);
}
$dbh_revs->disconnect();
$dbh_native->disconnect();
system("rm -rf $TMP_DIR") unless $DEBUG;

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

    # Clean up previous build files
    system("rm -f $BUILD_ARGS/$bid.src");
    system("rm -f $BUILD_ARGS/$bid.test");
    system("rm -f $PREEXEC_CMDS/$bid.src");
    system("rm -f $PREEXEC_CMDS/$bid.test");

    # Checkout v1
    $project->checkout_vid("${bid}b", $TMP_DIR, 1) == 1 or die;    

    # Construct the args files for compiling source and tests
    my $source_cp = "$ANALYZER_OUTPUT/$bid/source_cp";
    $project->run_mvn_build_classpath("compile", $source_cp);
    $project->construct_javac_args("${bid}b", $source_cp, 1, "$BUILD_ARGS/$bid.src", "$PREEXEC_CMDS/$bid.src");
    # Confirm that the args file is correct for compiling v1 source
    my $log;
    my $ret = $project->compile("$BUILD_ARGS/$bid.src", \$log);
    if (! $ret) {
        system("echo \"--------------------- Error compiling v1 source ${bid} --------------------- \n${log}\n\n\" >> $LOG");
    }
    _add_bool_result($data, $COMP_V1, $ret) or return 0;

    my $test_cp = "$ANALYZER_OUTPUT/$bid/test_cp";
    $project->run_mvn_build_classpath("test", $test_cp);
    $project->construct_javac_args("${bid}b", $test_cp, 0, "$BUILD_ARGS/$bid.test", "$PREEXEC_CMDS/$bid.test");
    # Confirm that the args file is correct for compiling v1t2 tests
    $ret = $project->compile("$BUILD_ARGS/$bid.test", \$log);
    if (! $ret) {
        system("echo \"--------------------- Error compiling v1t2 tests ${bid} --------------------- \n${log}\n\n\" >> $LOG");
    }
    _add_bool_result($data, $COMP_T2V1, $ret) or return 0;

    # Checkout v2
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) == 1 or die;

    # Confirm that the args file is correct for compiling v2 source
    $ret = $project->compile("$BUILD_ARGS/$bid.src", \$log);
    if (! $ret) {
        system("echo \"--------------------- Error compiling v2 source ${bid} --------------------- \n${log}\n\n\" >> $LOG");
    }
    _add_bool_result($data, $COMP_V2, $ret) or return 0;

    # Confirm that the args file is correct for compiling v2t2 tests
    $ret = $project->compile("$BUILD_ARGS/$bid.test", \$log);
    if (! $ret) {
        system("echo \"--------------------- Error compiling v2t2 tests ${bid} --------------------- \n${log}\n\n\" >> $LOG");
    }
    _add_bool_result($data, $COMP_T2V2, $ret) or return 0;
}

#
# Confirm that native test runs match maven test runs.
# TODO currently checks this for t2v2; does this also need to be done for t2v1?
#
# Returns 1 on success, 0 otherwise
#
sub _check_tests {
    my ($project, $bid, $data) = @_;

    my $project_path = $project->{prog_root};
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) or die;

    # Compile src and test
    $project->mvn_compile() or die;
    $project->mvn_test_compile() or die;

    # Run tests with Maven and get number of failing tests
    my $log;
    $project->run_mvn_tests(\$log) or die;
    my @mvn_failing = Utils::extract_failing_tests_mvn("$project_path/target/surefire-reports");
    my $num_fail_mvn = scalar(@mvn_failing);
    my $num_total_mvn = Utils::get_total_tests_mvn("$project_path/target/surefire-reports");

    # Extract test info from the Maven run
    my $junit_version = Utils::mvn_extract_test_info("$project_path/target/surefire-reports",
                                                     "$ANALYZER_OUTPUT/$bid/test_cp",
                                                     'target/classes',
                                                     'target/test-classes',
                                                     "$JUNIT_ARGS/$bid",
                                                     "$ALL_TESTSUITES/$bid",
                                                     "$ALL_TESTCASES/$bid");
    $project->add_to_junit_version_map("$bid", $junit_version);
    $project->run_mvn_clean();

    # Run tests natively and check getting same results as maven
    my $file = "$TMP_DIR/test.output"; `>$file`;
    $project->compile("$BUILD_ARGS/$bid.src");
    $project->compile("$BUILD_ARGS/$bid.test");
    $project->run_tests($bid, "$JUNIT_ARGS/$bid", "$PREEXEC_CMDS/$bid.src", "$PREEXEC_CMDS/$bid.test", $TEST_JAR, "$ALL_TESTSUITES/$bid", $file, 1);
    my $native_failing = Utils::get_failing_tests($file);
    my $num_fail_native = scalar(@{$native_failing->{"classes"}}) + scalar(@{$native_failing->{"methods"}});
    my ($num_total_native, $num_fail_summary_native) = Utils::get_test_summary($file);
    if ($num_fail_native != $num_fail_summary_native) {
        system("echo \"--------------------- Error extracting number of failing tests ${bid} --------------------- \n\" >> $LOG");
        system("echo \"NATIVE LOG: Total=$num_total_native,Failures=$num_fail_native\n\" >> $LOG");
        system("cat $file >> $LOG");
        return 0;
    }

    # Compare native and mvn test runs - there should be no failing tests and the same number of tests should be run
    my $check = $num_fail_native == 0 && $num_fail_mvn == 0 && $num_total_native == $num_total_mvn;
    if (! $check) {
        system("echo \"--------------------- Error comparing native and mvn test runs ${bid} --------------------- \n\" >> $LOG");
        system("echo \"MAVEN LOG: Total=$num_total_mvn,Failures=$num_fail_mvn\n\" >> $LOG");
        system("echo \'$log\' >> $LOG");
        system("echo \"NATIVE LOG: Total=$num_total_native,Failures=$num_fail_native\n\" >> $LOG");
        system("cat $file >> $LOG");
        $check = 0;
    }
    _add_bool_result($data, $COMPARE_TEST, $check) or return 0;
}


#
# Insert boolean success into hash
#
sub _add_bool_result {
    my ($data, $key, $success) = @_;
    $data->{$key} = $success;
}

#
# Add a rows to the database table
#
sub _add_rows {
    my ($data) = @_;

    # Save the revision results
    my @tmp;
    foreach (@COLS) {
        push (@tmp, $dbh_native->quote((defined $data->{$_} ? $data->{$_} : "-")));
    }
    my $row = join(",", @tmp);
    $dbh_native->do("INSERT INTO $TAB_NATIVE VALUES ($row)");
}

#
# Get bug ids from TAB_REV_PAIRS
#
sub _get_bug_ids {
    my $target_bid = shift;

    my $min_id;
    my $max_id;
    if (defined($target_bid) && $target_bid =~ /(\d+)(:(\d+))?/) {
        $min_id = $max_id = $1;
        $max_id = $3 if defined $3;
    }

    my $sth_exists = $dbh_native->prepare("SELECT * FROM $TAB_NATIVE WHERE $PROJECT=? AND $ID=?") or die $dbh_native->errstr;

    # Select all version ids from previous step in workflow
    my $sth = $dbh_revs->prepare("SELECT $ID FROM $TAB_REV_PAIRS WHERE $PROJECT=? "
                . "AND $COMP_T2V2=1") or die $dbh_revs->errstr;
    $sth->execute($PID) or die "Cannot query database: $dbh_revs->errstr";
    my @bids = ();
    foreach (@{$sth->fetchall_arrayref}) {
        my $bid = $_->[0];
        # Skip if project & ID already exist in DB file
        $sth_exists->execute($PID, $bid);
        next if ($sth_exists->rows !=0);

        # Filter ids if necessary
        next if (defined $min_id && ($bid<$min_id || $bid>$max_id));

        # Add id to result array
        push(@bids, $bid);
    }
    $sth->finish();

    return @bids;
}

=pod

=head1 SEE ALSO

Next step in workflow: F<get-trigger.pl>.

=cut
