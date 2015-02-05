import std.algorithm;
import std.array: empty, popFront, front, back;
import std.conv: to;
import std.datetime: Clock;
import std.file;
import std.path: buildPath, absolutePath, expandTilde, buildNormalizedPath;
import std.range;
import std.stdio;
import std.string;
import std.typecons: Flag, Yes, No;

/// Configuration loaded from command-line args.
struct Config
{
    /// Maximum number of external processes (`dub fetch`, `hmod`) to run simultaneously.
    size_t maxProcesses = 2;
    /// Directory where `dub` stores fetched packages.
    string dubDirectory;
    /// Max time in seconds any external process can run. If we run out of time, we give up.
    uint processTimeLimit = 60;
    /// Max age (seconds) of documentation before it must be regenerated even if it exists.
    ulong maxDocAge = 3600 * 24 * 7;
    /// Hmod will ignore any modules bigger than this many kiB.
    uint maxFileSizeK = 8192;
    /// Same as maxDocAge, for *branches* (e.g. ~master), not actual releases.
    ulong maxDocAgeBranch = 3600 * 24 * 2;
    /// Directory to write generated documentation into.
    string outputDirectory = "./doc";
    /// Path to write a YAML file with info about status of doc generation to (e.g. errors).
    string statusOutputPath = null;
    /// Names of packages to generate documentation for, in "package:version" format.
    string[] packageNames;
    /// Maximum number of times to retry fetching a package if we fail to receive data.
    uint maxFetchRetries = 2;
    /// Links to add to the TOC, in format "name:path", where path points to a local file.
    string[] additionalTocLinks = [];

    /// Initialize dubDirectory for current platform.
    void init()
    {
        version(linux)   { dubDirectory = "~/.dub/packages".expandTilde();               }
        version(Windows) { static assert (false, "Set default dubDirectory on Windows"); }
        version(OSX)     { static assert (false, "Set default dubDirectory on OSX");     }
    }
}

/// The help message printed when the `-h`/`--help` option is used.
string helpString = q"(
-------------------------------------------------------------------------------
hmod-dub
Generates DDoc documentation for DUB packages (code.dlang.org) using hmod.
Copyright (C) 2015 Ferdinand Majerech

Usage: hmod-dub [OPTIONS] package1 package2
       hmod-dub [OPTIONS] package1:version package2

Examples:
    hmod-dub dyaml:0.5.0 gfm
        Generate documentation for D:YAML 0.5.0 and the current git (~master)
        version of GFM. The documentation will be written into the './doc'
        directory.

Options:
    -h, --help                     Show this help message.
    -o, --output-directory DIR     Directory to write generated documentation
                                   into. The documentation for each package
                                   will be written into subdirectories in
                                   format DIR/PACKAGE-NAME/PACKAGE-VERSION .
                                   Default: ./doc
    -p, --process-count COUNT      Maximum number of external processes
                                   hmod-dub should launch. E.g. if 4, hmod-dub
                                   can fetch or generate documentation for 4
                                   packages at the same time.
                                   Default: 2
    -d, --dub-directory DIR        Directory where DUB stores fetched packages.
                                   Default (Linux): ~/.dub/packages
                                   Default (Windows/OSX): TODO
    -t, --process-time-limit SECS  Maximum time in seconds to allow any
                                   external process to run. E.g. if 10,
                                   hmod-dub gives up if fetching a package
                                   takes more than 10 seconds.
                                   Default: 60
    -a, --max-doc-age SECS         Maximum age of pre-existing documentation.
                                   hmod-dub writes '.time' files storing
                                   a timestamp specifying when the
                                   documentation
                                   Default: 604800 (7 days)
    -a, --max-doc-age-branch SECS  Same as maxDocAge, but for branches, not 
                                   release versions (e.g. ~master).
                                   Default: 172800 (2 days)
    -r, --max-fetch-retries TIMES  Maximum number of times to retry fetching
                                   a package if we failed to receive data.
                                   Default: 2
    -s, --status-output-path PATH  Path to write a YAML file with info about 
                                   documentation generation status (errors, 
                                   logs, etc.) for individual packages. If not
                                   specified, this file will not be written.
    -A, --additional-toc-link STR  Can be used more than once to add links 
                                   to specified files to the tables of contents 
                                   of generated documentation. STR is of format 
                                   "name:path" where path points to the current 
                                   directory, e.g. "DDocs.org:index.html". Can
                                   be used more than once to add more links.
    -m, --max-file-size KILOBYTES  Maximum module file size for `hmod` to 
                                   accept. Any modules bigger than this will be 
                                   ignored. Helps avoid huge RAM usage.
                                   Default: 8192 (8MiB)
-------------------------------------------------------------------------------
)";

/// Program entry point.
int main(string[] args)
{
    import std.getopt;

    Config config;
    config.init();
    bool doHelp;
    getopt(args, std.getopt.config.caseSensitive, std.getopt.config.passThrough,
           "h|help",                &doHelp,
           "p|process-count",       &config.maxProcesses,
           "d|dub-directory",       &config.dubDirectory,
           "t|process-time-limit",  &config.processTimeLimit,
           "a|max-doc-age",         &config.maxDocAge,
           "b|max-doc-age-branch",  &config.maxDocAgeBranch,
           "o|output-directory",    &config.outputDirectory,
           "r|max-fetch-retries",   &config.maxFetchRetries,
           "s|status-output-path",  &config.statusOutputPath,
           "A|additional-toc-link", &config.additionalTocLinks,
           "m|max-file-size",       &config.maxFileSizeK);

    // Returns the part with args that *don't* start with "-"
    config.packageNames = args[1 .. $];

    if(doHelp || config.packageNames.empty)
    {
        writeln(helpString);
        return 0;
    }

    try
    {
        writeln("Packages: ", config.packageNames.join(", "));
        return eventLoop(config);
    }
    catch(Throwable e)
    {
        writeln("FATAL ERROR: ", e);
        return 1;
    }
}

/** Stages of the "package documentation process".
 */
enum Stage
{
    /// The initial state. Nothing has been done yet with the package.
    Ready,
    /// `dub` is fetching the package.
    DubFetch,
    /** `dub` is done but we're waiting because of too many external processes running at
     * the moment. When done, we will run `hmod` on the package.
     */
    WaitingForHmod,
    /// `hmod` is generating documentation for the package.
    Hmod,
    /// Documentation has been successfully generated.
    Success,
    /// There was an error somewhere along the way; failed to generate documentation.
    Error
}

import std.process;

/** State of the "package documentation process" for a package.
 *
 * Contains package information, current stage, ID of any external process working on the
 * package, etc.
 */
struct PackageState
{
    /// Stage the package is currently in.
    Stage stage;
    /// Name of the package in the dub registry.
    string packageName;
    /// Version of the package (semver or ~branch).
    string packageVersion;
    /// Time when the currently running external process started in hnsecs since 1.1.1 AD.
    ulong processStartTime;
    /** Pid of the currently running external process, if any.
     *
     * This is the `dub fetch` process when `stage == Stage.DubFetch`
     * or the `hmod` process when `stage == Stage.Hmod`.
     */
    Pid processID;
    /// Error message if `stage == Stage.Error`
    string errorMessage;
    /// Log file to which stdout and stderr of the running external process is redirected.
    std.stdio.File log;

    /// The number of times we've retried to fetch the package.
    uint fetchRetryCount;

    /// Peak memory usage of the hmod subprocess, in kiB.
    ulong hmodPeakMemoryUsage;

    /// Errors that were detected for this package.
    string[] errors;

    /// True if we've actually generated the docs. False if skipped or failed during generation.
    bool didGenerateDocs = false;

    /** Finish working with the package because of an error.
     *
     * Closes the log file if open and sets `stage` to `stage.Error`.
     *
     * Params:
     *
     * message = The error message.
     */
    void finishError(string message)
    {
        if(log.isOpen) { log.close(); }
        if(errors.empty) { errors ~= "Unknown error"; }
        processID = Pid.init;
        stage = Stage.Error;
        errorMessage = message;
    }

    /// Reopen the log file if it's closed.
    void ensureLogOpen()
    {
        if(!log.isOpen) { log.open(log.name, "a"); }
    }

    /// Get the content of the log file. Can only be called when not running an external process.
    string logContent()
    {
        if(log == File.init) { return "<NO LOG CONTENT>"; }

        assert(processID is null || processID.processID < 0,
               "Trying to read log of a running process");
        const isOpen = log.isOpen;
        if(isOpen) { log.close(); }
        scope(exit) if(isOpen) { log.open(log.name, "a"); }
        return readText(log.name);
    }

    /// Delete the log file.
    void deleteLog()
    {
        if(log == File.init) { return; }
        const isOpen = log.isOpen;
        if(isOpen) { log.close(); }
        std.file.remove(log.name);
    }

    /** Finish working with the package after successfully generating documentation.
     *
     * Closes the log file if open and sets `stage` to `stage.Success`.
     *
     * Depending on `skipped`, writes a timestamp file specifying when the documentation
     * has been generated.
     *
     * Params:
     *
     * message = The error message.
     * skipped = Has documentation generation been skipped? If `Yes.skipped`, the
     *           timestamp file will not be written.
     */
    void finishSuccess(ref const Config config, Flag!"skipped" skipped = No.skipped)
    {
        processID = Pid.init;
        if(log.isOpen) { log.close(); }
        if(!skipped) try
        {
            File(config.outputDirectory.buildPath(timestampFile), "w")
                .writeln(Clock.currStdTime);
        }
        catch(Exception e)
        {
            writeln("Error writing timestamp file; ignoring");
        }

        stage = Stage.Success;
    }

    /// Get the time the current process has been running for, in seconds.
    float processAgeSeconds()
    {
        assert([Stage.DubFetch, Stage.Hmod].canFind(stage),
               "No process running at the moment");
        return hnsecs2secs(Clock.currStdTime - processStartTime);
    }

    /// Get the directory the package should be found in in the DUB package cache.
    string packageDirectory() const
    {
        auto ver = packageVersion.startsWith("~") ? packageVersion[1 .. $] : packageVersion;
        return packageName ~ "-" ~ ver.tr("+", "_");
    }

    /// Get the timestamp file path in `Config.outputDirectory`.
    string timestampFile() const
    {
        return docDirectory ~ ".time";
    }

    /// Get the documentation directory for this package in `Config.outputDirectory`.
    string docDirectory() const
    {
        return [packageName, packageVersion.tr("+", "_")].buildPath();
    }

    /// Is this a branch version (e.g. ~master)?
    bool isBranch() const { return packageVersion.startsWith("~"); }

    /// Is any external process running for this package at the moment?
    bool running() const { return [Stage.DubFetch, Stage.Hmod].canFind(stage); }

    /// Are we done processing this package (either succesfully or because of an error)?
    bool done() const { return [Stage.Success, Stage.Error].canFind(stage); }
}

/** Process package names to generate an array of PackageState structs with package name
 * and version from each package string.
 */
PackageState[] processPackageNames(const string[] packageNames) nothrow
{
    PackageState[] packages;
    foreach(str; packageNames)
    {
        auto parts = str.findSplit(":");
        string name = parts[0];
        string semver = parts[2].empty ? "~master" : parts[2];
        packages ~= PackageState(Stage.Ready, name, semver);
    }
    return packages;
}

/** Checks if the current process processing a package is done.
 *
 * Can only be called if the package is being processed by an external process.
 *
 * Params:
 *
 * pkg    = Package being processed.
 * what   = A string describing what is being done with the package.
 * config = hmod-dub configuration.
 * 
 *
 *
 * Returns: true if the currently running process for current package is done, false otherwise.
 */
bool successfullyDone(ref PackageState pkg, string what, ref const Config config)
{
    auto status = pkg.processID.tryWait;
    if(!status.terminated)
    {
        if(pkg.processAgeSeconds > config.processTimeLimit) with(pkg)
        {
            if(stage == Stage.DubFetch)  { errors ~= "'dub fetch' ran out of time"; }
            else if(stage == Stage.Hmod) { errors ~= "'hmod' ran out of time"; }
            else assert(false, "Checking for termination in unexpected stage");
            finishError("Ran out of time while " ~ what);
        }
        return false;
    }
    // Error return
    if(status.status != 0) with(pkg)
    {
        import std.regex;
        const log = logContent();
        enum fetchError     = "Error executing command fetch: ";
        enum noPackageError = fetchError ~ "No package";
        enum jsonError      = fetchError ~ `Got .*? of type \w*? - expected \w?`;
        enum tmpFileError   = fetchError ~ `Cannot open or create file '/tmp`;
        if(log.canFind("404"))             { errors ~= "Package file not found"; }
        if(log.canFind(noPackageError))    { errors ~= "No package with matching name/version"; }
        if(log.canFind(tmpFileError))      { errors ~= "dub fetch failed to create a /tmp file"; }
        if(!log.matchAll(jsonError).empty) { errors ~= "Error in dub.json of the package (hit by dub)"; }

        enum netError = fetchError ~ `Failure when receiving data from the peer on handle`;

        if(log.canFind(netError))
        {
            if(pkg.fetchRetryCount < config.maxFetchRetries)
            {
                writeln("Retrying to fetch package ", pkg.packageName);
                startDubFetch(pkg, config);
                ++pkg.fetchRetryCount;
                return false;
            }
            errors ~= "Failed when downloading the package";
        }
        pkg.finishError("Error while %s for package '%s:%s' (use -s to save subprocess logs)"
                        .format(what, pkg.packageName, pkg.packageVersion));
        return false;
    }
    // Get hmod memory usage even on success.
    else if(pkg.stage == Stage.Hmod)
    {
        auto memLine = pkg.logContent.splitLines.filter!(l => l.startsWith("Peak memory usage"));
        if(!memLine.empty) { pkg.hmodPeakMemoryUsage = memLine.front.split.back.to!ulong; }
    }

    return true;
}


/** Main event loop. Fetches and generates documentation for packages in external
 * processes limited to `config.maxProcesses`.
 *
 * Tries to handle errors specific to packages so documentation is still generated for
 * other packages.
 *
 * Throws:
 *
 * Exception in case of a fatal error that could not be recovered from.
 */
int eventLoop(ref const(Config) config)
{
    const startTime = Clock.currStdTime;
    PackageState[] packages = processPackageNames(config.packageNames);

    // Don't handle YAMLException, it is caught by the caller as fatal
    scope(exit) 
    {
        foreach(ref pkg; packages)
        {
            writefln("`hmod` memory usage (%s) (kiB): %s", 
                     pkg.packageName ~ ":" ~ pkg.packageVersion, pkg.hmodPeakMemoryUsage);
        }
        const peakMemory = peakMemoryUsageK();
        writefln("Peak `hmod-dub` memory usage (kiB): %s", peakMemory);

        if(config.statusOutputPath)
        {
            import yaml;
            Node[string] pkgNodes;
            foreach(ref pkg; packages)
            {
                pkgNodes["%s:%s".format(pkg.packageName,pkg.packageVersion)]
                    = Node(["errors":          Node(pkg.errors), 
                            "didGenerateDocs": Node(pkg.didGenerateDocs),
                            "subprocessLog":   Node(pkg.logContent),
                            "memoryHmodK":     Node(pkg.hmodPeakMemoryUsage)
                           ]);
            }

            Dumper(config.statusOutputPath).dump(Node(pkgNodes));
        }
        foreach(ref pkg; packages) { pkg.deleteLog(); }
    }

    for(size_t i = 0; packages.canFind!(p => !p.done); ++i)
    {
        // Sleep from time to time so we don't burn cycles waiting too much.
        if(i % 100 == 0)
        {
            import core.thread: Thread;
            import std.datetime: dur;

            Thread.sleep(dur!"msecs"(100));
            write(".");
        }

        foreach(ref pkg; packages)
        {
            const runningProcesses = packages.count!(p => p.running);
            final switch(pkg.stage) with(Stage)
            {
                case Ready:
                    if(runningProcesses < config.maxProcesses)
                    {
                        // If the docs have been generated recently, skip the entire
                        // generation process.
                        if(recentDocsExist(pkg, config)) { pkg.finishSuccess(config, Yes.skipped); }
                        // Need to ensure the directory (and log file for process) exists first
                        else if(initDirAndLog(pkg, config)) { startDubFetch(pkg, config); }
                    }
                    break;
                case DubFetch:
                    if(!successfullyDone(pkg, "fetching package", config))
                    {
                        break;
                    }
                    pkg.stage = WaitingForHmod;
                    goto case WaitingForHmod;
                case WaitingForHmod:
                    if(runningProcesses < config.maxProcesses) 
                    {
                        startHmod(pkg, config); 
                    }
                    break;
                case Hmod:
                    if(!successfullyDone(pkg, "generating documentation", config))
                    {
                        break;
                    }
                    pkg.didGenerateDocs = true;
                    pkg.finishSuccess(config);
                    break;
                case Success, Error:
                    break;
            }
        }
    }

    writefln("\nRun time: %.2fs", hnsecs2secs(Clock.currStdTime - startTime));

    int returnStatus = 0;
    writeln("\nRESULTS:\n");
    foreach(ref pkg; packages) switch(pkg.stage)
    {
        case Stage.Success:
            writefln("success: %s:%s", pkg.packageName, pkg.packageVersion);
            break;
        case Stage.Error:
            returnStatus = 2;
            writefln("ERROR:   %s:%s: %s", pkg.packageName, pkg.packageVersion, pkg.errorMessage);
            writefln("         errors: %s", pkg.errors);
            break;
        default: assert(false, "All processes must be done at this point");
    }

    return returnStatus;
}

/** Initialize a documentation output directory and log file.
 *
 * Creates the directory if not present and opens the log file, rewriting any previous
 * contents.
 *
 * Params:
 *
 * pkg    = Package to initialize for.
 * config = Hmod-dub configuration to get the output directory.
 *
 * Returns: `true` on success, `false` on failure.
 */
bool initDirAndLog(ref PackageState pkg, ref const Config config)
{
    try
    {
        const docDir = config.outputDirectory.buildPath(pkg.docDirectory);
        docDir.mkdirRecurse();
        pkg.log = File(docDir ~ ".log", "w");
    }
    // This is fatal
    catch(Exception e)
    {
        writefln("Failed to create directory/log for package %s:%s: %s", 
                 pkg.packageName, pkg.packageVersion, e.msg);
        throw e;
    }
    return true;
}

/** Start fetching a package with `dub fetch`.
 *
 * Will skip fetching the package if it's already present.
 *
 * Params:
 *
 * pkg    = Package to fetch. **Package stage will be changed based on whether fetching is
 *          in progress, has failed to start or has been skipped.**
 * config = Hmod-dub configuration to get the DUB directory.
 *
 * Throws:
 *
 * ProcessException in the fatal case where `dub` is not found/does not work.
 */
void startDubFetch(ref PackageState pkg, ref const Config config)
{
    writefln("\nFetching %s:%s", pkg.packageName, pkg.packageVersion);
    try
    {
        if(canSkipDubFetch(pkg, config)) 
        {
            pkg.stage = Stage.WaitingForHmod;
            return; 
        }

        auto args = ["dub", "fetch", pkg.packageName, "--version", pkg.packageVersion];
        writeln("Running: ", args.map!(a => "'%s'".format(a)).joiner(" "));
        pkg.ensureLogOpen();
        pkg.processID = spawnProcess(args, stdin, pkg.log, pkg.log);
        pkg.processStartTime = Clock.currStdTime;
        pkg.stage = Stage.DubFetch;
    }
    catch(ProcessException e)
    {
        // This is fatal
        writeln("Failed to start dub: maybe it's not installed / in PATH?");
        throw e;
    }
    catch(Exception e)
    {
        // Unknown error, but maybe not fatal
        pkg.finishError("Failed to fetch package: " ~ e.msg);
    }
}

/** Checks if we can skip fetching a package.
 *
 * If the package is a branch version, e.g. ~master, we must re-fetch it. 
 * Otherwise looks for `pkg.packageDirectory` in `config.dubDirectory`. If the directory
 * exists, we can skip fetching.
 *
 * This is needed because `dub` errors out if trying to re-fetch a package that is already
 * present.
 *
 * Returns: `true` if the package is already present, `false` otherwise.
 */
bool canSkipDubFetch(ref const PackageState pkg, ref const Config config)
{
    const packageDir = config.dubDirectory.buildPath(pkg.packageDirectory);
    writefln("Checking if %s exists (so we can skip fetching)", packageDir);
    if(packageDir.exists)
    {
        // We need to re-fetch a branch to get any new commits, and since dub protests
        // if the branch dir already exists, we need to delete it.
        if(pkg.isBranch()) 
        {
            rmdirRecurse(packageDir);
            return false;
        }
        writefln("No need to fetch: '%s' already exists", packageDir);
        return true;
    }
    return false;
}


/** Start generating documentation for a package with `hmod`.
 *
 * Params:
 *
 * pkg    = Package to generate documentation for. **Package stage will be changed
 *          based on whether documentation generation is in progress or has failed to
 *          start**
 * config = Hmod-dub configuration to get the DUB and output directories.
 *
 * Throws:
 *
 * ProcessException in the fatal case where `hmod` is not found/does not work.
 */
void startHmod(ref PackageState pkg, ref const Config config)
{
    writefln("\nGenerating documentation for %s:%s", pkg.packageName, pkg.packageVersion);
    try
    {
        auto packageDir = config.dubDirectory.buildPath(pkg.packageDirectory);
        writefln("Working directory for hmod: '%s'", packageDir);

        string[] sourceDirs = getSourceDirs(packageDir, &pkg.errors);
        const outputDir = config.outputDirectory.buildPath(pkg.docDirectory).absolutePath;

        pkg.ensureLogOpen();
        auto args = ["hmod"] ~ sourceDirs ~ 
                    ["--output-directory", outputDir,
                     "--project-name",     pkg.packageName,
                     "--max-file-size",    config.maxFileSizeK.to!string];
        foreach(link; config.additionalTocLinks)
        {
            const parts = link.findSplit(":");
            args ~= "--toc-additional-direct";
            const dir = "../".repeat(2 + pkg.packageName.count("/")).join.to!string;
            args ~= "[%s](%s)".format(parts[0], dir.buildPath(parts[2]));
        }
        writeln("Running: ", args.map!(a => "'%s'".format(a)).joiner(" "));

        pkg.processID = spawnProcess(args, stdin, pkg.log, pkg.log, null,
                                     std.process.Config.none, packageDir);
        pkg.processStartTime = Clock.currStdTime;
        pkg.stage = Stage.Hmod;
    }
    catch(ProcessException e)
    {
        // This is fatal
        writeln("Failed to start hmod: maybe it's not installed / in PATH?");
        throw e;
    }
    catch(Exception e)
    {
        // Unknown (or known, in case of 'No source paths') error, but maybe not fatal
        pkg.finishError("Failed to generate documentation: " ~ e.msg);
    }
}

/** Checks if we can skip generating documentation for a package.
 *
 * Looks for `pkg.timestampFile` in `config.outputDirectory`. If the file exists and the
 * timestamp is newer than `config.maxDocAge`, we can skip generating documentation.
 *
 * Returns: `true` if the timestamp file exists and is recent enough, `false` otherwise.
 */
bool recentDocsExist(ref const PackageState pkg, ref const Config config)
{
    const timestampPath = config.outputDirectory.buildPath(pkg.timestampFile);
    // Check if docs are already generated and recent enough not to regenerate
    if(timestampPath.exists) try
    {
        auto timestampFile = File(timestampPath, "r");
        ulong timestamp;
        timestampFile.readf("%s", &timestamp);
        const age = hnsecs2secs(Clock.currStdTime - timestamp);
        const maxAge = pkg.isBranch ? config.maxDocAgeBranch : config.maxDocAge;
        if(age <= maxAge)
        {
            const lastDay = age % (3600 * 24);
            writefln("\n%s:%s: Recent docs exist, no need to regenerate (%.0fd %.0fh %.2fs)",
                     pkg.packageName, pkg.packageVersion, 
                     age / (3600 * 24), lastDay / 3600, lastDay % 3600);
            return true;
        }
    }
    catch(Exception e)
    {
        writeln("Error reading timestamp file; ignoring");
    }
    return false;
}


/** Get an array of source directories in specified package directory to generate
 * documentation from.
 *
 * Returns:
 *
 * If `hmod.cfg` is found in the package, returns an empty array so `hmod` command line
 * does not override directories from `hmod.cfg`.
 *
 * If `hmod.cfg` is not found, looks for `dub.json` or `package.json` and reads
 * `importPaths` and `sourcePaths`, including those in any `subPackages`. If any of
 * the `subPackages` is represented as a path to a subdirectory, `getSourceDirs` is
 * recursively called to collect source paths from the subdirectory. All these paths
 * are then collected into the returned array.
 *
 * Params:
 *
 * packageDir = Directory storing the package to document.
 * errors     = Errors encountered will be written here. 
 *              May be null (we ignore errors in recursively loaded source dirs).
 *  
 * 
 *
 * Throws: Exception if `dub.json`/`package.json` is not found or there are no
 *         `importPaths`/`sourcePaths` in it.
 */
string[] getSourceDirs(string packageDir, string[]* errors)
{
    string[] sourceDirs;
    // If hmod.cfg exists, assume it specifies the source paths (this allows package
    // maintainers to specify for which files to generate docs).
    if(packageDir.buildPath("hmod.cfg").exists)
    {
        writeln("hmod.cfg found in the package. Assuming it specifies the source paths "
                "instead of getting them from dub.json .");
        return sourceDirs;
    }

    import std.json;
    // Called recursively if there are subpackages specified directly in JSON.
    // (entire getSourceDirs is called recursively if a subpackage is specified only by
    // its path)
    void addPaths(ref JSONValue parent)
    {
        foreach(string key, ref val; parent)
        {
            if(["importPaths", "sourcePaths"].canFind(key)) foreach(size_t idx, ref pathJSON; val)
            {
                // Avoid duplicate paths
                const path = pathJSON.str().buildNormalizedPath;
                if(!sourceDirs.canFind(path)) { sourceDirs ~= path == "" ? "." : path; }
            }
            else if(key == "subPackages") foreach(size_t idx, ref subPkg; val)
            {
                if(subPkg.type == JSON_TYPE.OBJECT) { addPaths(subPkg); }
                // Subpackages can also be paths pointing to a subpackage.
                else if(subPkg.type == JSON_TYPE.STRING)
                {
                    const subDirPath = subPkg.str();
                    const subPackageDir = packageDir.buildPath(subDirPath);
                    try if(subPackageDir.exists())
                    {
                        // We ignore errors in recursive calls (not ideal, but we can't
                        // really know which errors are 'fatal' and which are not)
                        foreach(dir; getSourceDirs(subPackageDir, null))
                        {
                            sourceDirs ~= subDirPath.buildPath(dir);
                        }
                    }
                    // Ignore so we don't fail to generate docs for the entire package
                    // due to a subpackage.
                    catch(Exception e)
                    {
                    }
                }
            }
            else if(key == "configurations") foreach(size_t idx, ref config; val)
            {
                addPaths(config);
            }
        }
    }


    try foreach(file; ["dub.json", "package.json"]) if(packageDir.buildPath(file).exists)
    {
        auto root = packageDir.buildPath(file).readText.parseJSON;
        addPaths(root);
    }
    catch(JSONException e)
    {
        const msg = "Error in dub.json of the package (hit when looking for source paths)";
        if(errors !is null) { *errors ~= msg; }
        writefln("dub.json/package.json in %s: %s", packageDir, e.msg);
        throw e;
    }
    if(sourceDirs.empty)
    {
        const msg = `No source paths found (need to add "sourcePaths"/"importPaths" to dub.json?)`;
        if(errors !is null) { *errors ~= msg;}
        throw new Exception(msg);
    }
    return sourceDirs;
}

ulong peakMemoryUsageK()
{
    version(linux)
    {
        try
        {
            import std.exception;
            auto line = File("/proc/self/status").byLine().filter!(l => l.startsWith("VmHWM"));
            enforce(!line.empty, new Exception("No VmHWM in /proc/self/status"));
            return line.front.split()[1].to!ulong;
        }
        catch(Exception e)
        {
            writeln("Failed to get peak memory usage: ", e);
            return 0;
        }
    }
    else 
    {
        writeln("peakMemoryUsageK not implemented on non-Linux platforms");
        return 0;
    }
}

/// Converts a time in hectonanoseconds to seconds.
double hnsecs2secs(ulong hnsecs) { return hnsecs / 10_000_000.0; }
