## packages



Extra packages on the sandbox ` PATH `, e\.g\. the project’s toolchain\.



*Type:*
list of package



*Default:*

```nix
[ ]
```



*Example:*

```nix
[ pkgs.ripgrep ]
```



## adapters

Tools the broker runs outside the sandbox on the agent’s behalf\. Their packages must not be in ` packages `\.



*Type:*
list of function that evaluates to a(n) (attribute set)



*Default:*

```nix
[ ]
```



*Example:*

```nix
[ zandy.adapters.gitlab (zandy.adapters.aws { profiles = [ "acme-dev" ]; }) ]
```



## backend\.bedrock



Run the model through Amazon Bedrock; the credentials come from the broker\.



*Type:*
null or (submodule)



*Default:*

```nix
null
```



*Example:*

```nix
{
  profile = "acme-bedrock";
  region = "eu-west-1";
}
```



## backend\.bedrock\.profile



AWS profile the broker exports Bedrock credentials from\.



*Type:*
string



## backend\.bedrock\.region



AWS region of Bedrock\.



*Type:*
string



## filesystem\.allowRead



Extra paths the agent may read\. Absolute, relative to the working directory, or starting with ` ~ `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## filesystem\.allowWrite



Extra paths the agent may write\. Absolute, relative to the working directory, or starting with ` ~ `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## filesystem\.denyRead



Paths the agent may not read\. Absolute, relative to the working directory, or starting with ` ~ `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## filesystem\.denyWrite



Paths the agent may not write\. Absolute, relative to the working directory, or starting with ` ~ `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## name



Name of the sandbox env; the launcher becomes ` bin/zandy-<name> `\.



*Type:*
string matching the pattern \[a-z0-9-]+



*Example:*

```nix
"claude"
```



## preset



The app to run and the sandbox rules it needs, e\.g\. ` zandy.presets.claude `\.



*Type:*
submodule



## preset\.packages



Packages the app needs, given ` pkgs `\.



*Type:*
function that evaluates to a(n) list of package



## preset\.args



Startup args, given ` { settings } `\.



*Type:*
function that evaluates to a(n) list of string



*Default:*

```nix
<function>
```



## preset\.binary



Binary in ` sandbox/bin ` to execute\.



*Type:*
string



## preset\.env



Names of the environment variables passed into the sandbox\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



## preset\.name



Name of the preset\.



*Type:*
string



## preset\.rules



SBPL rules the app needs\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```



## preset\.settings



App settings, given ` backend `\.



*Type:*
function that evaluates to a(n) raw value



*Default:*

```nix
<function>
```


