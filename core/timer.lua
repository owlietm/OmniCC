-- A pool of objects for determining what text to display for a given cooldown
-- and notify subscribers when the text change

-- local bindings!
local Addon = _G[...]
local L = _G.OMNICC_LOCALS
local After = _G.C_Timer.After
local floor = math.floor
local GetTime = _G.GetTime
local max = math.max
local next = next
local round = _G.Round
local strjoin = _G.strjoin
local tinsert = table.insert
local tremove = table.remove

-- sexy constants!
-- used for formatting text
local DAY, HOUR, MINUTE = 86400, 3600, 60
-- used for formatting text at transition points
local DAYISH, HOURISH, MINUTEISH, SOONISH = 3600 * 23.5, 60 * 59.5, 59.5, 5.5
-- used for calculating next update times
local HALFDAYISH, HALFHOURISH, HALFMINUTEISH = DAY / 2 + 0.5, HOUR / 2 + 0.5, MINUTE / 2 + 0.5
-- the minimum wait time for a timer
local MIN_DELAY = 0.01

-- internal state!
local active = {}
local inactive = {}

local Timer = {}
local Timer_mt = {__index = Timer}

function Timer:GetOrCreate(settings, start, duration, kind)
    -- start and duration can have milisecond precision
    -- convert them into ints when creating a key to avoid floating point weirdness
    local key = strjoin("-", settings.id or "", floor(start * 1000), floor(duration * 1000), kind or "")

    -- first, look for an already active timer
    -- if we don't have one, then either reuse an old one or create a new one
    local timer = active[key]

    if not timer then
        if next(inactive) then
            timer = tremove(inactive)

            timer.key = key
            timer.start = start
            timer.duration = duration
            timer.text = nil
            timer.state = nil
            timer.kind = kind
            timer.settings = settings
        else
            timer = setmetatable({
                key = key,
                start = start,
                duration = duration,
                settings = settings,
                kind = kind,
                subscribers = {}
            }, Timer_mt)

            timer.callback = function()
                timer:Update()
            end
        end

        active[key] = timer
        timer:Update()
    end

    return timer
end

function Timer:Update()
    if not active[self.key] then
        return
    end

    local remain = (self.duration - (GetTime() - self.start)) or 0

    if remain > 0 then
        local text, textSleep = self:GetTimerText(remain)
        if self.text ~= text then
            self.text = text

            for subscriber in pairs(self.subscribers) do
                subscriber:OnTimerTextUpdated(self, text)
            end
        end

        local state, stateSleep = self:GetTimerState(remain)
        if self.state ~= state then
            self.state = state

            for subscriber in pairs(self.subscribers) do
                subscriber:OnTimerStateUpdated(self, state)
            end
        end

        After(max(min(textSleep, stateSleep), MIN_DELAY), self.callback)
    elseif not self.finished then
        self.finished = true

        for subscriber in pairs(self.subscribers) do
            subscriber:OnTimerFinished(self)
        end

        self:Destroy()
    end
end

function Timer:Subscribe(subscriber)
    if self.subscribers[subscriber] then
        return
    end

    self.subscribers[subscriber] = true
    subscriber:OnTimerTextUpdated(self, self.text or "")
    subscriber:OnTimerStateUpdated(self, self.state or "seconds")
end

function Timer:Unsubscribe(subscriber)
    self.subscribers[subscriber] = nil

    if not next(self.subscribers) then
        self:Destroy()
    end
end

function Timer:Destroy()
    if active[self.key] then
        active[self.key] = nil

        self.settings = nil
        self.text = nil
        self.state = nil
        self.finished = nil

        for subscriber in pairs(self.subscribers) do
            subscriber:OnTimerDestroyed(self)
            self.subscribers[subscriber] = nil
        end

        tinsert(inactive, self)
    end
end

function Timer:GetTimerText(remain)
    local sets = self.settings
    local tenthsDuration = sets and sets.tenthsDuration or 0
    local mmSSDuration = sets and sets.mmSSDuration or 0

    if remain <= tenthsDuration then
        -- tenths of seconds
        local sleep = remain * 100 % 10 / 100

        return L.TenthsFormat:format(remain), sleep
    elseif remain < MINUTEISH then
        -- minutes
        local seconds = round(remain)

        local sleep = remain - max(
            seconds - 0.51,
            tenthsDuration
        )

        if seconds > 0 then
            return seconds, sleep
        end

        return "", sleep
    elseif remain <= mmSSDuration then
        -- MM:SS
        local seconds = round(remain)
        local sleep = remain - (seconds - 0.51)

        return L.MMSSFormat:format(seconds / MINUTE, seconds % MINUTE), sleep
    elseif remain < HOUR then
        -- minutes
        local minutes = round(remain / MINUTE)

        local sleep = remain - max(
            -- transition point of showing one minute versus another (29.5s, 89.5s, 149.5s, ...)
            (minutes * MINUTE - HALFMINUTEISH),
            -- transition point of displaying minutes to displaying seconds (59.5s)
            MINUTEISH,
            -- transition point of displaying MM:SS (user set)
            mmSSDuration
        )

        return L.MinuteFormat:format(minutes), sleep
    elseif remain < DAYISH then
        -- hours
        local hours = round(remain / HOUR)

        local sleep = remain - max(
            (hours * HOUR - HALFHOURISH),
            HOURISH
        )

        return L.HourFormat:format(hours), sleep
    else
        -- days
        local days = round(remain / DAY)

        local sleep = remain - max(
            (days * DAY - HALFDAYISH),
            DAYISH
        )

        return L.DayFormat:format(days), sleep
    end
end

function Timer:GetTimerState(remain)
    if remain <= 0 then
        return "finished", math.huge
    elseif self.kind == "loc" then
        return "controlled", math.huge
    elseif self.kind == "charge" then
        return "charging", math.huge
    elseif remain < SOONISH then
        return "soon", remain
    elseif remain < MINUTEISH then
        return "seconds", remain - SOONISH
    elseif remain < HOURISH then
        return "minutes", remain - MINUTEISH
    else
        return "hours", remain - HOURISH
    end
end

function Timer:ForActive(method, ...)
    for timer in pairs(active) do
        local func = timer[method]
        if type(func) == "function" then
            func(timer, ...)
        end
    end
end

Addon.Timer = Timer
