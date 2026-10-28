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



## gateway



The model backend the broker forwards to, adding auth outside the sandbox\.



*Type:*
null or (function that evaluates to a(n) (attribute set))



*Default:*

```nix
null
```



*Example:*

```nix
zandy.gateways.bedrock { profile = "acme-bedrock"; region = "eu-west-1"; }
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



Startup args\.



*Type:*
list of string



*Default:*

```nix
[ ]
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



## preset\.gatewayEnv



Env vars the app gets per gateway name, or a function of the gateway; ` {url} ` becomes the gateway’s address\.



*Type:*
attribute set of ((attribute set of string) or function that evaluates to a(n) attribute set of string)



*Default:*

```nix
{ }
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


