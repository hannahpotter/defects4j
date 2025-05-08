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

initialize-revisions.pl -- Initialize all revisions: identify the directory
layout and perform a sanity check for each revision.

=head1 SYNOPSIS

initialize-revisions.pl -p project_id -w work_dir [-s subproject] [ -b bug_id] [-D]

=head1 OPTIONS

=over 4

=item B<-p C<project_id>>

The id of the project for which the meta data should be generated.

=item B<-w F<work_dir>>

The working directory used for the bug-mining process.

=item B<-s F<subproject>>

The subproject to be mined (if not the root directory)

=item B<-b C<bug_id>>

Only analyze this bug id. The bug_id has to follow the format B<(\d+)(:(\d+))?>.
Per default all bug ids, listed in the active-bugs csv, are considered.

=item B<-D>

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=back

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
getopts('p:b:w:s:D', \%cmd_opts) or pod2usage(1);

pod2usage(1) unless defined $cmd_opts{p} and defined $cmd_opts{w};

my $PID = $cmd_opts{p};
my $BID = $cmd_opts{b};
my $WORK_DIR = abs_path($cmd_opts{w});
my $SUBPROJ = $cmd_opts{s};
$DEBUG = 1 if defined $cmd_opts{D};

# Check format of target bug id
if (defined $BID) {
    $BID =~ /^(\d+)(:(\d+))?$/ or die "Wrong version id format ((\\d+)(:(\\d+))?): $BID!";
}

# Add script and core directory to @INC
unshift(@INC, "$WORK_DIR/framework/core");

# Override global constants
$REPO_DIR = "$WORK_DIR/project_repos";
$PROJECTS_DIR = "$WORK_DIR/framework/projects";

# Create necessary directories
my $PROJECT_DIR = "$PROJECTS_DIR/$PID";
my $PATCH_DIR   = "$PROJECT_DIR/patches";
my $ANALYZER_OUTPUT = "$PROJECT_DIR/analyzer_output";
my $DEPENDENCIES = "$PROJECT_DIR/lib/dependency";

-d $PROJECT_DIR or die "$PROJECT_DIR does not exist: $!";
-d $PATCH_DIR or die "$PATCH_DIR does not exist: $!";

system("mkdir -p $ANALYZER_OUTPUT $DEPENDENCIES");

# DB_CSVs directory
my $db_dir = $WORK_DIR;

# Temporary directory
my $TMP_DIR = Utils::get_tmp_dir();
system("mkdir -p $TMP_DIR");

# Set up project
my $project = Project::create_project($PID);

# Get database handle for results
my $dbh = DB::get_db_handle($TAB_BOOTSTRAP, $db_dir);
my @COLS = DB::get_tab_columns($TAB_BOOTSTRAP) or die;

#
# Initialize a specific version id.
#
sub _init_version {
    my ($project, $bid, $vid) = @_;

    my $work_dir = "${TMP_DIR}/${vid}";
    $project->{prog_root} = $work_dir;

    my $rev_id = $project->lookup("${vid}");

    # Use the VCS checkout routine, which does not apply the cached, possibly
    # minimized patch to obtain the buggy version.
    $project->{_vcs}->checkout_vid("${vid}", $work_dir) or die "Cannot checkout $vid version";

    if (defined $SUBPROJ) {
        $work_dir .= "/$SUBPROJ/";
        $project->{prog_root} = $work_dir;
    }

    system("mkdir -p $ANALYZER_OUTPUT/$bid");

    $project->initialize_revision($rev_id, "${vid}");

    return ($rev_id, $work_dir, $project->src_dir("${vid}"), $project->test_dir("${vid}"));
}

#
# Init routine for Maven builds.
#
sub _init_maven {
    my ($work_dir, $bid, $rev_id) = @_;

    if (! -e "$work_dir/pom.xml") {         
        system("echo \"--------------------- Error with revision ${rev_id} --------------------- \nNo pom file\" >> $ANALYZER_OUTPUT/INITIALIZE_REVISIONS.txt");
        return 0; 
    }

    # Update the pom.xml to update pom elements.
    Utils::fix_dependency_urls("$work_dir/pom.xml", "$UTIL_DIR/fix_pom_dependency_urls.patterns", 1) if -e "$work_dir/pom.xml";
    Utils::fix_pom("$work_dir/pom.xml", "$UTIL_DIR/fix_pom_elements.patterns", "$UTIL_DIR/fix_pom_plugins.patterns") if -e "$work_dir/pom.xml";

    # Check for dependencies that can't be resolved
    my $check_dep = "cd $work_dir && mvn dependency:resolve";
    my $log;
    if (! Utils::exec_cmd($check_dep, "Checking dependencies for pom.xml.", \$log)) {
        system("echo \"--------------------- Error with revision ${rev_id} --------------------- \nError with dependencies\n${log}\" >> $ANALYZER_OUTPUT/INITIALIZE_REVISIONS.txt");
        return 0;
    }

    # Copy dependencies to project lib/dependency (ignores dependency if local copy already exists)
    my $copy_dep = "cd $work_dir && mvn dependency:copy-dependencies -Dmdep.copyPom=true -DoutputDirectory=$DEPENDENCIES -Dmdep.useRepositoryLayout=true" or die "Cannot copy maven dependencies";
    Utils::exec_cmd($copy_dep, "Copying dependencies for pom.xml.");

    # Construct classpaths for compiling and running source and test code
    my $source_classpath = "cd $work_dir && mvn dependency:build-classpath -DincludeScope=compile -Dmdep.outputFile=$ANALYZER_OUTPUT/$bid/source_cp -Dmdep.localRepoProperty=".'\$LOCAL_DEPENDENCY_PATH';
    Utils::exec_cmd($source_classpath, "Constructing source classpath");
    my $test_classpath = "cd $work_dir && mvn dependency:build-classpath -DincludeScope=test -Dmdep.outputFile=$ANALYZER_OUTPUT/$bid/test_cp -Dmdep.localRepoProperty=".'\$LOCAL_DEPENDENCY_PATH';
    Utils::exec_cmd($test_classpath, "Constructing test classpath");

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
# Check size of src diff for a given candidate bug (bid).
#
# Returns 1 on success, 0 otherwise
#
sub _check_diff {
    my ($project, $bid, $data) = @_;

    # Determine patch size for src and test patches (rev2 -> rev1)
    my $patch_test = "$PATCH_DIR/$bid.test.patch";
    my $patch_src = "$PATCH_DIR/$bid.src.patch";

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
# The Defects4J core framework requires certain metadata for each defect. This
# routine creates these artifacts, if necessary.
#
sub _bootstrap {
    my ($data, $project, $bid) = @_;

    my ($v1, $work_dir_b, $src_b, $test_b) = _init_version($project, $bid, "${bid}b");
    my ($v2, $work_dir_f, $src_f, $test_f) = _init_version($project, $bid, "${bid}f");
    if ($v1 eq "" || $v2 eq "") {
        return 0;
    }

    die "Source directories don't match for buggy and fixed revisions of $bid" unless $src_b eq $src_f;
    die "Test directories don't match for buggy and fixed revisions of $bid" unless $test_b eq $test_f;

    # Create local patch so that we can use the D4J core framework.
    # Minimization doesn't matter here, which has to be done manually.
    $project->export_diff($v2, $v1, "$PATCH_DIR/$bid.src.patch", "$src_f");
    $project->export_diff($v2, $v1, "$PATCH_DIR/$bid.test.patch", "$test_f");

    # Defects4J cannot handle empty patch files -> filter out these candidates.
    if (! _check_diff($project, $bid, $data)) {
        printf("      -> Skipping - empty patch\n");
        $data->{$BOOTSTRAPPED} = 0;
        return 0;
    }

    my $maven_success = _init_maven($work_dir_b, $bid, $v1) && _init_maven($work_dir_f, $bid, $v2);
    if (! $maven_success) {
        printf("      -> Skipping - error with bug\n");
    }
    $data->{$BOOTSTRAPPED} = $maven_success;
    return $maven_success;
}

my @ids = $project->get_bug_ids();
if (defined $BID) {
    if ($BID =~ /(\d+):(\d+)/) {
        @ids = grep { ($1 <= $_) && ($_ <= $2) } @ids;
    } else {
        # single bid
        @ids = grep { ($BID == $_) } @ids;
    }
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
    $dbh->do("INSERT INTO $TAB_BOOTSTRAP VALUES ($row)");
}

# Clean up previous log files
system("rm -f $ANALYZER_OUTPUT/INITIALIZE_REVISIONS.txt");
my $sth = $dbh->prepare("SELECT * FROM $TAB_BOOTSTRAP WHERE $PROJECT=? AND $ID=?") or die $dbh->errstr;
foreach my $bid (@ids) {
    printf ("%4d: $project->{prog_name}\n", $bid);

    # Skip existing entries
    $sth->execute($PID, $bid);
    if ($sth->rows !=0) {
        printf("      -> Skipping (existing entry in $TAB_BOOTSTRAP)\n");
        next;
    }

    # Clean up previously generated data
    system("rm -rf $ANALYZER_OUTPUT/${bid} $PATCH_DIR/${bid}.src.patch $PATCH_DIR/${bid}.test.patch");

    my %data;
    $data{$PROJECT} = $PID;
    $data{$ID} = $bid;
    # Populate the layout map and patches directory
    my $bootstrap_success = _bootstrap(\%data, $project, $bid);
    _add_row(\%data);
    if (! $bootstrap_success) {
        next;
    }

    # Clean the temporary directory
    Utils::exec_cmd("rm -rf $TMP_DIR && mkdir -p $TMP_DIR", "Cleaning working directory")
            or die "Cannot clean working directory";
    $project->{prog_root} = $TMP_DIR;
    $project->checkout_vid("${bid}f", $TMP_DIR, 1) or die "Cannot checkout fixed version";
    #$project->sanity_check();
}
$dbh->disconnect();
system("rm -rf $TMP_DIR") unless $DEBUG;
