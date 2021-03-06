#!/usr/bin/env lua

-- Bash completion generator for the mpv media player
-- Compatible with Lua 5.{1,2,3} and LuaJIT

-- Set the following environment variables to pass parameters. Other
-- ways of interfacing are not supported:
--
--    MPV_BASHCOMPGEN_VERBOSE     Enable debug output on stderr
--    MPV_BASHCOMPGEN_MPV_CMD     mpv binary to use. Defaults to 'mpv',
--                                using the shell's $PATH.

local VERBOSE     = not not os.getenv("MPV_BASHCOMPGEN_VERBOSE") or false
local MPV_CMD     = os.getenv("MPV_BASHCOMPGEN_MPV_CMD") or "mpv"
local MPV_VERSION = "unknown"
local LOOKUP      = nil

if _VERSION == "Lua 5.1" then table.unpack = unpack end

-----------------------------------------------------------------------
-- Shell and stdio ops
-----------------------------------------------------------------------

local function log(s, ...)
  if VERBOSE then
    io.stderr:write(string.format(s.."\n", ...))
  end
end

-- Reporting on optionList() result
local function debug_categories(ot)
  if not VERBOSE then return end
  local lines = {}
  local function count(t)
    local n = 0
    for e,_ in pairs(t) do
      n = n + 1
    end
    return n
  end
  local sum = 0
  for cat,t in pairs(ot) do
    local c = count(t)
    table.insert(lines, string.format(" %s: %d", cat, count(t)))
    sum = sum + c
  end
  table.sort(lines)
  table.insert(lines, 1, string.format("Found %d options:", sum))
  log(table.concat(lines, "\n"))
end

local function basename(s)
  return s:match("^.-([^/]+)$")
end

local function run(cmd, ...)
  local argv = table.concat({...}, " ")
  log("%s %s", cmd, argv)
  return assert(io.popen(string.format("%s " .. argv, cmd), "r"))
end

local function mpv(...)
  return run(MPV_CMD, "--no-config", ...)
end

local function assert_read(h, w)
  return assert(h:read(w or "*all"), "can't read from file handle: no data")
end

-----------------------------------------------------------------------
-- Table ops
-----------------------------------------------------------------------

local function oneOf(n, ...)
  for _,v in ipairs{...} do
    if n == v then return true end
  end
  return false
end

local function map(t, f)
  local u = {}
  for _,v in ipairs(t) do
    table.insert(u, f(v))
  end
  return u
end

local function mapcat   (t, f, c) return table.concat(map(t, f), c) end
local function mapcats  (t, f)    return mapcat(t, f, " ") end
local function mapcator (t, f)    return mapcat(t, f, "|") end

local function unique(t)
  local u, f = {}, {}
  for _,v in pairs(t) do
    if v and not f[v] then
      table.insert(u, v)
      f[v] = true
    end
  end
  return u
end

-- pairs() replacement with iterating using sorted keys
local function spairs(t)
  assert(t)

  local keys = {}
  for kk,_ in pairs(t) do
    table.insert(keys, kk)
  end

  local len = #keys
  local xi = 1

  local function snext(t, index)
    if not t
      or (index and index == len)
      or len == 0 then
      return nil
    elseif index == nil then
      local k = keys[xi]
      return k, t[k]
    else
      xi = xi + 1
      local k = keys[xi]
      return k, t[k]
    end
  end

  table.sort(keys)
  return snext, t, nil
end

local function keys(t)
  local u = {}
  if t then
    for k,_ in spairs(t) do
      table.insert(u, k)
    end
  end
  return u
end

-----------------------------------------------------------------------
-- Option processing
-----------------------------------------------------------------------

local function normalize_nums(xs)
  local xs = xs
  for i=#xs,1,-1 do
    local e = xs[i]
    local n = tonumber(e)
    if n then
      -- [ 1.0 1 -1.0 -1 ] -> [ 1.0 -1.0 ]
      if e:match("%.0") then
        for j=#xs,1,-1 do
          if i ~= j then
            local k = tonumber(xs[j])
            if k and k == n then table.remove(xs, j) end
          end
        end
      end
      -- [ 1.000000 ] -> [ 1.0 ]
      xs[i] = tostring(n)
    end
  end
  return xs
end

local Option = setmetatable({}, {
  __call = function (t, clist)
    local o = {}
    if type(clist)=="table" and #clist > 0 then
      o.clist = unique(clist)
      o.clist = normalize_nums(o.clist)
    end
    return setmetatable(o, { __index = t })
  end
})

local function getMpvVersion()
  local h = mpv("--version")
  local s = assert_read(h, "*line")
  h:close()
  return s:match("^%S+ (%S+)")
end

local function expandObject(o)
  local h = mpv(string.format("--%s=help", o))
  local clist = {}

  local function lineFilter(line)
    if line:match("^Available")
    or line:match("^%s+%(other")
    or line:match("^%s+demuxer:")
    then
      return false
    end
    return true
  end

  for l in h:lines() do
    local m = l:match("^%s+([%S.]+)")
    if lineFilter(l) and m then
      -- oac, ovc special case: filter out --foo=needle
      local tail = m:match("^--[^=]+=(.*)$")
      if tail then
        log(" ! %s :: %s -> %s", o, m, tail)
        m = tail
      end
      table.insert(clist, m)
    end
  end
  h:close()
  return clist
end

local function split(s, delim)
  assert(s)
  local delim = delim or ","
  local parts = {}
  for p in s:gmatch(string.format("[^%s]+", delim)) do
    table.insert(parts, p)
  end
  return parts
end

local function expandChoice(o)
  local h = mpv(string.format("--%s=help", o))
  local clist = {}
  for l in h:lines() do
    local m = l:match("^Choices: ([%S,.-]+)")
    if m then
      local choices = split(m, ",")
      for _,v in ipairs(choices) do
        log(" + %s += [%s]", o, v)
        table.insert(clist, v)
      end
    end
  end
  return clist
end

local function getRawVideoMpFormats()
  local h = mpv("--demuxer-rawvideo-mp-format=help")
  local line = assert_read(h)
  local clist = {}
  line = line:match(": (.*)")
  for f in line:gmatch("%w+") do
    table.insert(clist, f)
  end
  h:close()
  return clist
end

local function extractChoices(tail)
  local sub = tail:match("Choices: ([^()]+)")
  local clist = {}
  for c in sub:gmatch("%S+") do
    table.insert(clist, c)
  end
  return clist
end

local function extractDefault(tail)
  return tail:match("default: ([^)]+)")
end

local function extractRange(tail)
  local a, b = tail:match("%(([%d.-]+) to ([%d.-]+)%)")
  if a and b then
    return tostring(a), tostring(b)
  else
    return nil
  end
end

local function wantsFile(op, tail)
  local m = tail:match("%[file%]")
  if m then return true end

  for _,re in ipairs{ "%-file[s]?%-", "^script[s]?", "^scripts%-.*" } do
    if op:match(re) then return true end
  end

  return false
end

local function hasNoCfg(tail)
  local m = tail:match("%[nocfg%]") -- or tail:match("%[global%]") -- Fuck.
  return m and true or false
end

local function parseOpt(t, lu, group, o, tail)
  local ot = tail:match("(%S+)")
  local clist = nil

  -- Overrides for wrongly option type labels
  -- Usually String: where it should have been Object
  if oneOf(o, "opengl-backend",
              "opengl-hwdec-interop",
              "audio-demuxer",
              "cscale-window",
              "demuxer",
              "dscale",
              "dscale-window",
              "scale-window",
              "sub-demuxer") then
    ot = "Object"
  end

  if oneOf(o, "audio-spdif") then
    ot = "ExpandableChoice"
  end

  -- Override for dynamic profile list expansion
  if o:match("^profile") or o == "show-profile" then
    ot = "Profile"
  end

  -- Override for dynamic DRM connector list expansion
  if oneOf(o, "drm-connector") then
    ot = "DRMConnector"
  end

  -- Override for codec/format listings which are of type String, not
  -- object
  if oneOf(o, "ad", "vd", "oac", "ovc") then
    ot = "Object"
  end

  if oneOf(ot, "Integer", "Double", "Float", "Integer64")
                            then clist = { extractDefault(tail), extractRange(tail) }
                                 ot = "Numeric"
  elseif ot == "Flag"       then if hasNoCfg(tail)
                                    or o:match("^no%-")
                                    or o:match("^[{}]$") then ot = "Single"
                                 else clist = { "yes", "no", extractDefault(tail) } end
  elseif ot == "Audio"      then clist = { extractDefault(tail), extractRange(tail) }
  elseif ot == "Choices:"   then clist = { extractRange(tail), extractDefault(tail), table.unpack(extractChoices(tail)) }
                                 ot = "Choice"
  elseif ot == "ExpandableChoice" then clist = expandChoice(o)
                                       ot = "Choice"
  elseif ot == "Color"      then clist = { "#ffffff", "1.0/1.0/1.0/1.0" }
  elseif ot == "FourCC"     then clist = { "YV12", "UYVY", "YUY2", "I420", "other" }
  elseif ot == "Image"      then clist = lu.videoFormats
  elseif ot == "Int[-Int]"  then clist = { "j-k" }
                                 ot = "Numeric"
  elseif ot == "Key/value"  then ot = "String"
  elseif ot == "Object"     then clist = expandObject(o)
  elseif ot == "Output"     then clist = { "all=no", "all=fatal", "all=error", "all=warn", "all=info", "all=status", "all=v", "all=debug", "all=trace" }
                                 ot = "String"
  elseif ot == "Relative"   then clist = { "-60", "60", "50%" }
                                 ot = "Position"
  elseif ot == "String"     then if wantsFile(o, tail) then
                                   ot = "File"
                                   if o:match('directory') or o:match('dir') then
                                     ot = "Directory"
                                   end
                                 else
                                   clist = { extractDefault(tail) }
                                 end
  elseif ot == "Time"       then clist = { "00:00:00" }
  elseif ot == "Window"     then ot = "Dimen"
  elseif ot == "Profile"    then clist = {}
  elseif ot == "DRMConnector" then clist = {}
  elseif ot == "alias"      then clist = { tail:match("^alias for (%S+)") or "" }
                                 ot = "Alias"
  else
    ot = "Single"
  end

  local oo = Option(clist)
  log(" + %s :: %s -> [%s]", o, ot, oo.clist and table.concat(oo.clist, " ") or "")

  if group then
    t[ot] = t[ot] or {}
    t[ot][o] = oo
  else
    t[o] = oo
  end
end

local function getAVFilterArgs2(o, f)
  local h = mpv(string.format("--%s %s=help", o, f))
  local t = {}
  for l in h:lines() do
    local o, tail = l:match("^%s([%w%-]+)%s+(%S.*)")
    if o then parseOpt(t, LOOKUP, false, o, tail) end
  end
  h:close()
  return t
end

local function optionList()
  local t = {}
  local prev_s = nil
  local h = mpv("--list-options")

  for s in h:lines() do
    -- Regular, top-level options
    local o, ss = s:match("^%s+%-%-(%S+)%s+(%S.*)")
    if o then
      prev_s = ss
      parseOpt(t, LOOKUP, true, o, ss)
    else
      -- Second-level options (--vf-add, --vf-del etc)
      local o = s:match("^%s+%-%-(%S+)")
      if o then
        parseOpt(t, LOOKUP, true, o, prev_s)
      end
    end
  end

  h:close()

  -- Expand filter arguments

  local function stem(name)
    local bound = name:find("-", 1, true)
    if bound then
      return name:sub(1, bound-1)
    end
    return name
  end

  local fargs = {}
  if t.Object then
    for name, value in pairs(t.Object) do
      if name:match("^vf") or name:match("^af") then
        local stem = stem(name)
        for _, filter in ipairs(value.clist or {}) do
          fargs[stem]         = fargs[stem] or {}
          fargs[stem][filter] = fargs[stem][filter] or getAVFilterArgs2(stem, filter)
          fargs[name]         = fargs[stem]
        end -- for
      end -- if
    end -- for
  end -- if
  setmetatable(t, { fargs = fargs })

  -- Resolve new-style aliases

  local function find_option(name)
    for group, members in pairs(t) do
      for o, oo in pairs(members) do
        if o == name then
          return group, oo
        end
      end
    end
    return nil
  end

  if t.Alias then
    for name, val in pairs(t.Alias) do
      local alias = table.remove(val.clist)
      local group, oo = find_option(alias)
      if group then
        log(" * %s is an alias of %s[%s]", name, group, alias)
        t[group][name] = oo
      end
    end
    t.Alias = nil
  end

  return t
end

local function createScript(olist)
  local lines = {}

  local function ofType(...)
    local t = {}
    for _,k in ipairs{...} do
      if olist[k] then
        for u,v in spairs(olist[k]) do
          t[u] = v
        end
      end
    end
    return spairs(t)
  end

  local function emit(...)
    for _,e in ipairs{...} do
      table.insert(lines, e)
    end
  end

  emit([[#!/bin/bash
# mpv ]]..MPV_VERSION)

  emit([[### LOOKUP TABLES AND CACHES ###
declare _mpv_xrandr_cache
declare _mpv_use_media_globexpr=0
declare _mpv_media_globexpr='@(mp?(e)g|MP?(E)G|wm[av]|WM[AV]|avi|AVI|asf|ASF|vob|VOB|bin|BIN|dat|DAT|vcd|VCD|ps|PS|pes|PES|fl[iv]|FL[IV]|fxm|FXM|viv|VIV|rm?(j)|RM?(J)|ra?(m)|RA?(M)|yuv|YUV|mov|MOV|qt|QT|mp[234]|MP[234]|m4[av]|M4[AV]|og[gmavx]|OG[GMAVX]|w?(a)v|W?(A)V|dump|DUMP|mk[av]|MK[AV]|m4a|M4A|aac|AAC|m[24]v|M[24]V|dv|DV|rmvb|RMVB|mid|MID|t[ps]|T[PS]|3g[p2]|3gpp?(2)|mpc|MPC|flac|FLAC|vro|VRO|divx|DIVX|aif?(f)|AIF?(F)|m2t?(s)|M2T?(S)|vdr|VDR|xvid|XVID|ape|APE|gif|GIF|nut|NUT|bik|BIK|webm|WEBM|amr|AMR|awb|AWB|iso|ISO|opus|OPUS)?(.part)'
declare -A _mpv_fargs
declare -A _mpv_pargs]])
  local fargs = getmetatable(olist).fargs
  for o,fv in spairs(fargs) do
    for f,pv in spairs(fv) do
      local plist = table.concat(keys(pv), "= ")
      if #plist > 0 then
        plist = plist.."="
        emit(string.format([[_mpv_fargs[%s@%s]="%s"]], o, f, plist))
      end
      for p,pa in spairs(pv) do
        plist = pa.clist and table.concat(pa.clist, " ") or ""
        if #plist > 0 then
          emit(string.format([[_mpv_pargs[%s@%s@%s]="%s"]], o, f, p, plist ))
        end
      end
    end
  end

  emit([=[### HELPER FUNCTIONS ###
_mpv_uniq(){
  local -A w
  local o=""
  for ww in "$@"; do
    if [[ -z "${w[$ww]}" ]]; then
      o="${o}${ww} "
      w[$ww]=x
    fi
  done
  printf "${o% }"
}
_mpv_profiles(){
  type mpv &>/dev/null || return 0;
  mpv --profile help  \
  | awk '{if(NR>2 && $1 != ""){ print $1; }}'
}
_mpv_drm_connectors(){
  type mpv &>/dev/null || return 0;
  mpv --no-config --drm-connector help \
  | awk '/\<connected\>/{ print $1 ; }'
}
_mpv_xrandr(){
  if [[ -z "$_mpv_xrandr_cache" && -n "$DISPLAY" ]] && type xrandr &>/dev/null; then
    _mpv_xrandr_cache=$(xrandr|while read l; do
      [[ $l =~ ([0-9]+x[0-9]+) ]] && echo "${BASH_REMATCH[1]}"
    done)
    _mpv_xrandr_cache=$(_mpv_uniq $_mpv_xrandr_cache)
  fi
  printf "$_mpv_xrandr_cache"
}
_mpv_s(){
  local cmp=$1
  local cur=$2
  COMPREPLY=($(compgen -W "$cmp" -- "$cur"))
}
_mpv_objarg(){
  local prev=${1#--} p=$2 r s t k f
  shift 2
  # Parameter arguments I:
  # All available parameters
  if [[ $p =~ : && $p =~ =$ ]]; then
    # current filter
    s=${p##*,}
    s=${s%%:*}
    # current parameter
    t=${p%=}
    t=${t##*:}
    # index key
    k="$prev@$s@$t"
    if [[ ${_mpv_pargs[$k]+x} ]]; then
      for q in ${_mpv_pargs[$k]}; do
        r="${r}${p}${q} "
      done
    fi

  # Parameter arguments II:
  # Fragment completion
  elif [[ ${p##*,} =~ : && ${p##*:} =~ = ]]; then
    # current filter
    s=${p##*,}
    s=${s%%:*}
    # current parameter
    t=${p%=}
    t=${t##*:}
    t=${t%%=*}
    # index key
    k="$prev@$s@$t"
    # fragment
    f=${p##*=}
    if [[ ${_mpv_pargs[$k]+x} ]]; then
      for q in ${_mpv_pargs[$k]}; do
        if [[ $q =~ ^${f} ]]; then
          r="${r}${p%=*}=${q} "
        fi
      done
    fi

  # Filter parameters I:
  # Suggest all available parameters
  elif [[ $p =~ :$ ]]; then
    # current filter
    s=${p##*,}
    s=${s%%:*}
    # index key
    k="$prev@$s"
    for q in ${_mpv_fargs[$k]}; do
      r="${r}${p}${q} "
    done

  # Filter parameters II:
  # Complete fragment
  elif [[ ${p##*,} =~ : ]]; then
    s=${p##*,}
    s=${s%%:*}
    # current argument
    t=${p##*:}
    # index key
    k="$prev@$s"
    for q in ${_mpv_fargs[$k]}; do
      if [[ $q =~ ^${t} ]]; then
        r="${r}${p%:*}:${q} "
      fi
    done

  # Filter list I:
  # All available filters
  elif [[ $p =~ ,$ ]]; then
    for q in "$@"; do
      r="${r}${p}${q} "
    done

  # Filter list II:
  # Complete fragment
  else
    s=${p##*,}
    for q in "$@"; do
      if [[ $q =~ ^${s} ]]; then
        r="${r}${p%,*},${q} "
      fi
    done
  fi
  printf "${r% }"
}]=])

  emit([=[### COMPLETION ###
_mpv(){
  local cur=${COMP_WORDS[COMP_CWORD]}
  local prev=${COMP_WORDS[COMP_CWORD-1]}
  # handle --option=a|b|c and --option a=b=c
  COMP_WORDBREAKS=${COMP_WORDBREAKS/=/}
  # handle --af filter=arg,filter2=arg
  COMP_WORDBREAKS=${COMP_WORDBREAKS/:/}
  COMP_WORDBREAKS=${COMP_WORDBREAKS/,/}]=])

  local all = setmetatable({}, {
    __call = function (t, o)
      table.insert(t, string.format("--%s", o))
    end
  })

  emit([=[if [[ -n $cur ]]; then case "$cur" in]=])
  for o,p in ofType("Choice", "Flag") do
    emit(string.format([[--%s=*)_mpv_s '%s' "$cur"; return;;]],
        o, mapcats(p.clist, function (e) return string.format("--%s=%s", o, e) end)))
    table.insert(all, string.format("--%s=", o))
  end
  emit("esac; fi")

  emit([=[if [[ -n $prev && ( $cur =~ , || $cur =~ : ) ]]; then case "$prev" in]=])
  for o,p in ofType("Object") do
    if o:match("^[av][fo]") then
      emit(string.format([[--%s)_mpv_s "$(_mpv_objarg "$prev" "$cur" %s)" "$cur";return;;]],
        o, p.clist and table.concat(p.clist, " ") or ""))
    end
  end
  emit("esac; fi")

  emit([=[if [[ -n $prev ]]; then case "$prev" in]=])
  if olist.File then
    emit(string.format("%s)_filedir;return;;",
      mapcator(keys(olist.File), function (e)
        local o = string.format("--%s", e)
        table.insert(all, o)
        return o
      end)))
  end
  if olist.Profile then
    emit(string.format([[%s)_mpv_s "$(_mpv_profiles)" "$cur";return;;]],
      mapcator(keys(olist.Profile), function (e)
        local o = string.format("--%s", e)
        table.insert(all, o)
        return o
      end)))
  end
  if olist.DRMConnector then
    emit(string.format([[%s)_mpv_s "$(_mpv_drm_connectors)" "$cur";return;;]],
      mapcator(keys(olist.DRMConnector), function (e)
            local o = string.format("--%s", e)
            table.insert(all, o)
            return o
    end)))
  end
  if olist.Directory then
    emit(string.format("%s)_filedir -d;return;;",
      mapcator(keys(olist.Directory), function (e)
        local o = string.format("--%s", e)
        table.insert(all, o)
        return o
      end)))
  end
  for o, p in ofType("Object", "Numeric", "Audio", "Color", "FourCC", "Image",
    "String", "Position", "Time") do
    if p.clist then table.sort(p.clist) end
    emit(string.format([[--%s)_mpv_s '%s' "$cur"; return;;]],
      o, p.clist and table.concat(p.clist, " ") or ""))
    all(o)
  end
  for o,p in ofType("Dimen") do
    emit(string.format([[--%s)_mpv_s "$(_mpv_xrandr)" "$cur";return;;]], o))
    all(o)
  end
  emit("esac; fi")

  emit("if [[ $cur =~ ^- ]]; then")
  for o,_ in ofType("Single") do all(o) end
  emit(string.format([[_mpv_s '%s' "$cur"; return;]],
    table.concat(all, " ")))
  emit("fi")

  emit([=[
if [[ $_mpv_use_media_globexpr -eq 1  && -n "$_mpv_media_globexpr" ]] ; then
  _filedir "$_mpv_media_globexpr"
else
  _filedir
fi
]=])

  emit("}", "complete -o nospace -F _mpv "..basename(MPV_CMD))
  return table.concat(lines, "\n")
end

-----------------------------------------------------------------------
-- Entry point
-----------------------------------------------------------------------

local function main()
  MPV_VERSION = getMpvVersion()
  LOOKUP = { videoFormats = getRawVideoMpFormats() }
  local l = optionList()
  debug_categories(l)
  print(createScript(l))
  return 0
end

os.exit(main())
