/// Build-time installer for the development image (loaded into %SYS by iris.script).
Class App.Installer
{

XData CreateNamespaceManifest [ XMLNamespace = INSTALLER ]
{
<Manifest>
    <Log Text="Creating namespace ${Namespace}" Level="0"/>
    <Namespace Name="${Namespace}" Create="yes" Code="${Namespace}-CODE" Data="${Namespace}-DATA" Ensemble="1">
        <Configuration>
            <Database Name="${Namespace}-DATA" Dir="${DataDBPath}" Create="yes" MountRequired="true" Resource="%DB_${Namespace}" PublicPermissions="RW" MountAtStartup="true"/>
            <Database Name="${Namespace}-CODE" Dir="${CodeDBPath}" Create="yes" MountRequired="true" Resource="%DB_${Namespace}" PublicPermissions="RW" MountAtStartup="true"/>
        </Configuration>
    </Namespace>
</Manifest>
}

ClassMethod RunCreateNamespace(ByRef pVars, pLogLevel As %Integer = 0, pInstaller As %Installer.Installer) As %Status [ CodeMode = objectgenerator, Internal ]
{
    Quit ##class(%Installer.Manifest).%Generate(%compiledclass, %code, "CreateNamespaceManifest")
}

/// Create a namespace with separate CODE and DATA databases.
///
/// set vars("Namespace")="APP"
/// set vars("DataDBPath")="/opt/irisapp/db/APP-DATA"
/// set vars("CodeDBPath")="/opt/irisapp/db/APP-CODE"
/// do ##class(App.Installer).CreateNamespace(.vars)
ClassMethod CreateNamespace(ByRef vars) As %Status
{
    set ret = $$$OK
    try {
        $$$ThrowOnError(..RunCreateNamespace(.vars))
    } catch ex {
        set ret = ex.AsStatus()
    }
    quit ret
}

}
