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
By default all bug ids that were successfully bootstrapped, listed in F<C<work_dir>/$TAB_BOOTSTRAP>, are considered.

=item B<-D>

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=back

=head1 DESCRIPTION

Runs the following worflow for all candidate bugs that were successfully bootstrapped, listed in F<C<work_dir>/$TAB_BOOTSTRAP>,
or (if -b is specified) for a subset of candidates:

=over 4

=item 1) Checkout fixed revision.

=item 2) Compile src and test.

=item 3) Apply src patch (fixed -> buggy).

=item 4) Compile src and test.

=item 5) Checkout fixed version.

=item 6) Run tests and log failing tests to F<C<PROJECTS_DIR>/<PID>/failing_tests>.

=item 7) Exclude failing tests, recompile and rerun. This is repeated until
         there are no more failing tests in F<$TEST_RUNS> consecutive
         executions. (Maximum limit of looping in this phase is specified by
         F<$MAX_TEST_RUNS>).

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

# Check format of target version id
if (defined $BID) {
    $BID =~ /^(\d+)(:(\d+))?$/ or die "Wrong version id format ((\\d+)(:(\\d+))?): $BID!";
}

# Add script and core directory to @INC
unshift(@INC, "$WORK_DIR/framework/core");

# Override global constants
# Set the projects and repository directories to the current working directory
$REPO_DIR = "$WORK_DIR/project_repos";
$PROJECTS_DIR = "$WORK_DIR/framework/projects";

my $FAILING_DIR = "$PROJECTS_DIR/$PID/failing_tests";
my $DEPENDENCIES = "$PROJECTS_DIR/$PID/lib/dependency";

-d $FAILING_DIR or die "$FAILING_DIR does not exist: $!";
-d $DEPENDENCIES or die "$DEPENDENCIES does not exist: $!";

# Keep log of issues
my $LOG = "$PROJECTS_DIR/$PID/analyze_project_error_log.txt";

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
my $dbh_revs = DB::get_db_handle($TAB_REV_PAIRS, $db_dir);
my $dbh_bootstrap = DB::get_db_handle($TAB_BOOTSTRAP, $db_dir);
my @REV_COLS = DB::get_tab_columns($TAB_REV_PAIRS) or die;

# Clean up previous log files
system("rm -f $LOG");
my @bids = _get_bug_ids($BID);
foreach my $bid (@bids) {
    printf ("%4d: $project->{prog_name}\n", $bid);

    # Keep track of revision data
    my %rev_data;
    $rev_data{$PROJECT} = $PID;
    $rev_data{$ID} = $bid;
    $rev_data{$ISSUE_TRACKER_NAME} = $TRACKER_NAME;
    $rev_data{$ISSUE_TRACKER_ID} = $TRACKER_ID;

    # Clean previous results
    my $v2 = $project->lookup("${bid}f");
    `rm $FAILING_DIR/$v2` if -e "$FAILING_DIR/$v2";

    _check_compilation($project, $bid, \%rev_data) and
    _export_tests($project, $bid, \%rev_data);

    # Add data set to result file
    _add_rows(\%rev_data);
}
$dbh_revs->disconnect();
$dbh_bootstrap->disconnect();
system("rm -rf $TMP_DIR") unless $DEBUG;

#
# Check whether v1, v2, and t2 can be compiled and export args for javac.
#
# Returns 1 on success, 0 otherwise
#
sub _check_compilation {
    my ($project, $bid, $rev_data) = @_;

    # Lookup revision ids
    my $v1  = $project->lookup("${bid}b");
    my $v2  = $project->lookup("${bid}f");

    my $project_path = $project->{prog_root};

    # Checkout v1
    $project->checkout_vid("${bid}b", $TMP_DIR, 1) == 1 or die;

    # Check that the v1 and t2 compile with maven
    my $ret = _try_command($project, \&Project::mvn_compile, "Error compiling source v1 for bug ${bid}");
    _add_bool_result($rev_data, $COMP_V1, $ret) or return 0;

    $ret = _try_command($project, \&Project::mvn_test_compile, "Error compiling tests v1t2 for bug ${bid}");
    _add_bool_result($rev_data, $COMP_T2V1, $ret) or return 0;

    # Checkout v2
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) == 1 or die;

    # Check that the v2 and t2 compile with maven
    $ret = _try_command($project, \&Project::mvn_compile, "Error compiling source v2 for bug ${bid}");
    _add_bool_result($rev_data, $COMP_V2, $ret) or return 0;

    $ret = _try_command($project, \&Project::mvn_test_compile,  "Error compiling tests v2t2 for bug ${bid}");
    _add_bool_result($rev_data, $COMP_T2V2, $ret) or return 0;
}

#
# Export failing tests in v2t2 to exclude.
#
# Returns 1 on success, 0 otherwise
#
sub _export_tests {
    my ($project, $bid, $rev_data) = @_;

    my $project_path = $project->{prog_root};

    # Lookup revision ids
    my $v2 = $project->lookup("${bid}f");

    # Checkout v2
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) == 1 or die;

    my $successful_runs = 0;
    my $run = 1;
    while ($successful_runs < $TEST_RUNS && $run <= $MAX_TEST_RUNS) {
        # Automatically fix broken tests and recompile
        $project->fix_tests("${bid}f");
        $project->mvn_test_compile();

        # Run t2 tests with maven and get the number of failing tests
        my $ret = _try_command($project, \&Project::run_mvn_tests, "Error running tests for bug ${bid}");
        if (! $ret) {
            $rev_data->{$FAIL_T2V2} = '-';
            return 0;
        }
	
        # Get number of failing tests
        my $file = "$TMP_DIR/v2.fail"; `>$file`;
        my @list = Utils::extract_failing_tests_mvn("$project_path/target/surefire-reports", $file);
        my $fail = scalar(@list);
        if ($run == 1) {
            $rev_data->{$FAIL_T2V2} = $fail;
        } else {
            $rev_data->{$FAIL_T2V2} += $fail;
        }

        ++$successful_runs;
        # Append to log if there were (new) failing tests
        unless ($fail == 0) {
            open(OUT, ">>$FAILING_DIR/$v2") or die "Cannot write failing tests: $!";
            print OUT "## $project->{prog_name}: $v2 ##\n";
            close OUT;
            system("cat $file >> $FAILING_DIR/$v2");
            $successful_runs = 0;
        }
        system("rm $file");          

        ++$run;
    }

    return 1;
}

#
# Attempts the maven command. Log any errors.
# 
sub _try_command {
    @_ == 3 or die $ARG_ERROR;
    my ($project, $mvn_cmd, $err_msg) = @_;

    my $log;
    my $ret = $mvn_cmd->($project, \$log);
    if (! $ret) {
        system("echo \"--------------------- $err_msg --------------------- \n${log}\n\n\" >> $LOG");
    }

    return $ret;
}

#
# Insert boolean success into hash
#
sub _add_bool_result {
    my ($data, $key, $success) = @_;
    $data->{$key} = $success;
}

#
# Add a rows to the database tables
#
sub _add_rows {
    my ($rev_data) = @_;

    # Save the revision results
    my @rev_tmp;
    foreach (@REV_COLS) {
        push (@rev_tmp, $dbh_revs->quote((defined $rev_data->{$_} ? $rev_data->{$_} : "-")));
    }
    my $rev_row = join(",", @rev_tmp);
    $dbh_revs->do("INSERT INTO $TAB_REV_PAIRS VALUES ($rev_row)");
}

#
# Get bug ids from BOOTSTRAP
#
sub _get_bug_ids {
    my $target_bid = shift;

    my $min_id;
    my $max_id;
    if (defined($target_bid) && $target_bid =~ /(\d+)(:(\d+))?/) {
        $min_id = $max_id = $1;
        $max_id = $3 if defined $3;
    }

    my $sth_exists = $dbh_revs->prepare("SELECT * FROM $TAB_REV_PAIRS WHERE $PROJECT=? AND $ID=?") or die $dbh_revs->errstr;

    # Select all version ids from previous step in workflow
    my $sth = $dbh_bootstrap->prepare("SELECT $ID FROM $TAB_BOOTSTRAP WHERE $PROJECT=? "
                . "AND $BOOTSTRAPPED=1") or die $dbh_bootstrap->errstr;
    $sth->execute($PID) or die "Cannot query database: $dbh_bootstrap->errstr";
    my @bids = ();
    foreach (@{$sth->fetchall_arrayref}) {
        my $bid = $_->[0];

        # Filter ids if necessary
        next if (defined $min_id && ($bid<$min_id || $bid>$max_id));

        # Skip if project & ID already exist in DB file
        $sth_exists->execute($PID, $bid);
        if ($sth_exists->rows !=0) {
            printf ("%4d: $project->{prog_name}\n", $bid);
            printf("      -> Skipping (existing entry in $TAB_REV_PAIRS)\n");
            next;
        };

        # Add id to result array
        push(@bids, $bid);
    }
    $sth->finish();

    return @bids;
}

=pod

=head1 SEE ALSO

Previous step in workflow: Manually verify that all test failures
(failing_tests) are valid and not spurious, broken, random, or due to classpath
issues.

Next step in workflow: F<extract-native.pl>.

=cut
