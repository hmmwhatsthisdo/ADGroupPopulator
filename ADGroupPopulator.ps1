[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        Resolve-Path $_
    })]
    [String]$ConfigPath
)

begin {
    # Load the configuration file
    try {

        Write-Verbose "Loading configuration file..."
        
        If ([String]::IsNullOrEmpty($ConfigPath) -or -not (Test-Path $ConfigPath -ErrorAction SilentlyContinue)) {
			Write-Verbose "Using default configuration file path."
            $ConfigPath = Join-Path $PSScriptRoot "..\Data\Configuration.xml" -Resolve
        }

        $ConfigObject = ([xml](Get-Content -LiteralPath $ConfigPath -ErrorAction Stop)).GroupPopConfig

        Write-Verbose "Configuration file loaded."
    }
    catch {
        throw "Failed to load XML Configuration file from $ConfigPath`: $_"
    }

    # # Validate that the XML matches the schema
    # $ConfigObject.Schemas.Add($null, (Join-Path $PSScriptRoot "ConfigSchema.xsd"))

    # $ConfigObject.Validate({
    #     throw "Failed to validate `"$ConfigPath`" against schema: $_"
    # })

    # Rehydrate credentials as necessary

    Write-Verbose "Retrieving credentials..."

    $Script:Credentials = @{}

    $ConfigObject.Meta.Credentials.Credential | ForEach-Object {
        Write-Verbose "Parsing credential entry `"$($_.Name)`" of type `"$($_.Type)`"."
        $Script:Credentials[$_.Name] = $(
            $CredNode = $_
            switch ($_.Type) {
                "CMS-JSON" { 
                    $UnpackedCredential = Get-Content -LiteralPath $CredNode.Path | Unprotect-CmsMessage | ConvertFrom-Json
                    Write-Output ([pscredential]::new($UnpackedCredential.Username, ($UnpackedCredential.Password | ConvertTo-SecureString -AsPlainText -Force)))
					Remove-Variable UnpackedCredential
					[gc]::Collect()
                }
                "CLIXML" {
                    Import-CLIXML -LiteralPath (Join-Path $PSScriptRoot $CredNode.Path -Resolve)
                }
                Default {
                    throw "Unrecognized credential type $($_.Type)"
                }
            }
        )
    }

    Write-Verbose "Setting default credential to `"$($ConfigObject.Meta.Credentials.Default)`"."
    
    $DefaultCredential = $Script:Credentials[$ConfigObject.Meta.Credentials.Default]

    Write-Verbose "Credential retrieval complete."

    If ($ConfigObject.Meta.Domain) {
        Write-Verbose "Setting target domain to `"$($ConfigObject.Meta.Domain.TargetDomain)`"."
        $TargetDomain = $ConfigObject.Meta.Domain.TargetDomain
    }

    If ($ConfigObject.Meta.Domain.DefaultSearchFilter) {
        $Script:DefaultSearchFilter = $ConfigObject.Meta.Domain.DefaultSearchFilter
    }

    $Script:DefaultADParams = @{
        Server = $TargetDomain
        Credential = $DefaultCredential
    }

    function Resolve-SourceDescriptorNode {
        [CmdletBinding()]
        param (
            # The XML node to resolve.
            [Parameter(
                ValueFromPipeline
            )]
            [System.Xml.XmlElement[]]
            $Descriptor
        )
        
        begin {
        }
        
        process {

            $Descriptor | Where-Object Name | ForEach-Object {
                $SourceNode = $_

                Write-Debug "Processing $($_.Name) source-descriptor"

                Switch ($SourceNode.Name) {
                    "ADGroup" {
                        $ADParams = $Script:DefaultADParams.Clone()
                        If ($SourceNode.Server) {
                            $ADParams["Server"] = $SourceNode.Server
                        }
                        If ($SourceNode.Credential) {
                            $ADParams["Credential"] = $Script:Credentials[$SourceNode.Credential]
                        }

                        $ADParams["Identity"] = $SourceNode.Identity
                        If ($SourceNode.Recursive) {
                            $ADParams["Recurse"] = [convert]::ToBoolean($SourceNode.Recursive)
                        }
						Write-Verbose "[ADGroup] $(If ($ADParams["Recurse"]) {"Recursively retrieving"} Else {"Retrieving"}) members of $($ADParams["Identity"])..."
                        Get-ADGroupMember @ADParams
                    }
                    "ADOrganizationalUnit" {
                        $ADParams = $Script:DefaultADParams.Clone()

                        If ($SourceNode.Server) {
                            $ADParams["Server"] = $SourceNode.Server
                        }
                        If ($SourceNode.Credential) {
                            $ADParams["Credential"] = $Script:Credentials[$SourceNode.Credential]
                        }

                        $ADParams["SearchBase"] = $SourceNode.Identity
                        $ADParams["SearchScope"] = $(If ($SourceNode.SearchScope) {$SourceNode.SearchScope} Else {"OneLevel"})
                        $ADParams["Filter"] = $(
                            If ($Script:DefaultSearchFilter) {
                                "($Script:DefaultSearchFilter) $(If ($SourceNode.Filter) {"-and ($($SourceNode.Filter))"})"
                            } Else {
                                $SourceNode.Filter
                            }
                        )
						Write-Verbose "[ADOrganizationalUnit] Performing $($ADParams["SearchScope"]) search on OU `"$($ADParams["SearchBase"])`"..."
                        Get-ADObject @ADParams
                    }
                    Default {
                        throw "Unrecognized source-type `"$_`"."
                    }
                }
            }
        }
        
        end {
        }
    }
}

process {

    Write-Verbose "Processing targets..."
    # Iterate through the list of targets
    $ConfigObject.Targets.Target | ForEach-Object {
        Write-Verbose "Processing target group `"$($_.Identity)`"."
        $TargetNode = $_

        $ADParams = $Script:DefaultADParams.Clone()
        $ADParams["Identity"] = $TargetNode.Identity

        If ($TargetNode.Server) {
            $ADParams["Server"] = $TargetNode.Server
        }
        If ($TargetNode.Credential) {
            $ADParams["Credential"] = $Script:Credentials[$TargetNode.Credential]
        }

        $TargetGroup = Get-ADGroup @ADParams

        $ADParams["Identity"] = $TargetGroup

        # Retrieve candidate members 
        Write-Verbose "Retrieving candidate members..."
        $TargetNode.Include.ChildNodes | Resolve-SourceDescriptorNode | Select-Object -Unique | Set-Variable CandidateMembers
        Write-Verbose "$($CandidateMembers.Count) candidates found."

        # Retrieve exclusionary members
        Write-Verbose "Retrieving exclusions..."
        $TargetNode.Exclude.ChildNodes | Resolve-SourceDescriptorNode | Select-Object -Unique | Set-Variable ExcludedMembers
        Write-Verbose "$($ExcludedMembers.Count) exclusions found."

		# Calcluate final member list
		If ($CandidateMembers -and $ExcludedMembers) {
		
			
			$ComputedMemberList = Compare-Object $CandidateMembers $ExcludedMembers -IncludeEqual | Where-Object SideIndicator -eq "<=" | ForEach-Object InputObject
		
		} Elseif ($CandidateMembers) {
		
			$ComputedMemberList = $CandidateMembers
		
		} Else {
		
			Write-Warning "Target `"$($TargetNode.Identity)`" has empty inclusion/exclusion sets."
			$ComputedMemberList = @()
		
		}
        
        Write-Debug "Synchronization set contains $($ComputedMemberList.Count) members."

		Write-Verbose "Retrieving current member list for comparison..."
        # Retrieve current members of the group to determine what needs to be added/removed
        $CurrentMemberList = Get-ADGroupMember @ADParams

		Write-Debug "Comparing between computed and current member lists."
        # Perform the comparison between target/current members
        $MemberComparison = Compare-Object $ComputedMemberList $CurrentMemberList -IncludeEqual

        $DeltaAddMemberList = $MemberComparison | Where-Object SideIndicator -eq "<=" | ForEach-Object InputObject
        $DeltaRemMemberList = $MemberComparison | Where-Object SideIndicator -eq "=>" | ForEach-Object InputObject

        Write-Verbose "$($DeltaAddMemberList.Count) members will be added, $($DeltaRemMemberList.Count) removed."

        Write-Verbose "Synchronizing changes with Active Directory..."

		If ($DeltaRemMemberList) {
			Remove-ADGroupMember @ADParams -Members $DeltaRemMemberList
		}
        If ($DeltaAddMemberList) {
			Add-ADGroupMember @ADParams -Members $DeltaAddMemberList
		}
		
        Write-Verbose "Membership update for `"$($TargetNode.Identity)`" complete."
    }
}

end {
}
