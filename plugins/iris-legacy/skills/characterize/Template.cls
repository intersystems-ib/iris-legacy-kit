/// Characterization tests for LABEL^RTN: today's behaviour, pinned before anything changes.
/// Copy this file into the project's test package, rename the class (and the file), replace
/// the examples with the routine's real entry points, and keep the helpers as they are.
/// Run it against the unchanged code first: every test must pass there.
Class App.Test.Legacy.RtnCharacterization Extends %UnitTest.TestCase
{

/// What a label prints. Run it with the current device redirected to a temporary file, and
/// return the output with "|" for each line feed. Assert after Capture returns, never while the
/// file is the current device (assertion output would end up in the file).
ClassMethod Capture(entry As %String) As %String
{
    set io = $io, f = ##class(%File).TempFilename("txt")
    open f:"WNS":2 else  quit "<cannot open "_f_">"
    use f
    try { do @entry } catch ex { write "<", ex.Name, " ", ex.Location, ">" }
    close f
    use io
    quit ..ReadFile(f, 1)
}

/// A label that READs from the terminal: run it as a job whose input is a file with one answer
/// per line (each element of answers), and return what it printed ("|" for each line feed).
/// The job does not inherit local variables: entry is a class method of this class that sets
/// what the label expects (U, inputs) and then calls it, for example "DriveList".
ClassMethod Drive(entry As %String, answers As %List, timeout As %Integer = 10) As %String
{
    set io = $io, in = ##class(%File).TempFilename("txt"), out = ##class(%File).TempFilename("txt")
    open in:"WNS":2 else  quit "<cannot open "_in_">"
    use in
    for i = 1:1:$listlength(answers) { write $listget(answers, i), ! }
    close in
    use io
    // Argument indirection sees only literals here (a class method's variables are private).
    set arg = "##class("_$classname()_")."_entry_"():(:"""":"""_in_""":"""_out_"""):5"
    job @arg
    else  quit "<job did not start>"
    set child = $zchild
    for i = 1:1:(timeout * 10) { quit:'$data(^$JOB(child))  hang 0.1 }
    if $data(^$JOB(child)) { do $system.Process.Terminate(child) quit "<job still running after "_timeout_" s: it waited for more input>" }
    do ##class(%File).Delete(in)
    quit ..ReadFile(out, 1)
}

ClassMethod ReadFile(f As %String, delete As %Boolean = 0) As %String [ Private ]
{
    set s = ##class(%Stream.FileCharacter).%New()
    do s.LinkToFile(f)
    set text = s.Read(10000000)
    kill s
    do:delete ##class(%File).Delete(f)
    quit $replace($replace(text, $char(13), ""), $char(10), "|")
}

/// Example job entry for Drive: set what the label expects, then call it.
ClassMethod DriveList()
{
    set U = "^"
    do LIST^RTN
}

/// Example: a list label that leaves its result in ^TMP($job,...). Pin the result, not how it
/// was built, and clean up after.
Method TestListByDate() [ PublicList = (U, FROM, TO) ]
{
    new U, FROM, TO
    set U = "^", FROM = $zdateh("2026-10-14", 3), TO = $zdateh("2026-10-15", 3)
    kill ^TMP($job)
    do BYDATE^RTN
    set n = 0, k = "" for { set k = $order(^TMP($job, "OL", k)) quit:k=""  set n = n + 1 }
    do $$$AssertEquals(n, 37, "BYDATE^RTN lists 37 orders for 14-15 Oct today")
    kill ^TMP($job)
}

/// Example: printed output, exact. Short outputs: the whole text. Long ones: a few exact lines
/// plus a fingerprint of the rest ($zcrc(text, 7)), so any change shows up.
Method TestPrintedOutput() [ PublicList = (U, N) ]
{
    new U, N
    set U = "^", N = 5
    set out = ..Capture("RECENT^RTN")
    do $$$AssertEquals($piece(out, "|", 1), "", "RECENT^RTN starts with an empty line today")
    do $$$AssertEquals($zcrc(out, 7), 123456789, "RECENT^RTN output for N=5, as printed today")
}

/// Example: an interactive label, driven through its prompts.
Method TestInteractiveList()
{
    set out = ..Drive("DriveList", $listbuild("14/10/2026", "15/10/2026"))
    do $$$AssertTrue(out [ "Orders from", "LIST^RTN shows its heading today")
    do $$$AssertNotTrue(out [ "<", "LIST^RTN completes without an error or a wait for input")
}

/// Example: side effects that must not change: no transaction left open, no lock left held.
Method TestNoLeftovers() [ PublicList = (U, CID) ]
{
    new U, CID
    set U = "^", CID = 1
    do BYCUST^RTN
    do $$$AssertEquals($tlevel, 0, "no transaction left open")
    kill ^TMP($job)
}

}
