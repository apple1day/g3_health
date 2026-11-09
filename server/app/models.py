from __future__ import annotations

import re
from datetime import date
from typing import Annotated, Literal, Self
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

NonNegative = Annotated[float, Field(ge=0, allow_inf_nan=False)]
Status = Literal["ok", "empty", "error"]
ShortText = Annotated[str, Field(max_length=160)]


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


class Sleep(Model):
    status: Status
    startedAt: AwareDatetime | None = None
    endedAt: AwareDatetime | None = None
    totalMinutes: NonNegative | None = None
    coreMinutes: NonNegative | None = None
    deepMinutes: NonNegative | None = None
    remMinutes: NonNegative | None = None
    unspecifiedMinutes: NonNegative | None = None
    awakeMinutes: NonNegative | None = None
    sourceName: ShortText | None = None

    @model_validator(mode="after")
    def check_interval(self) -> Self:
        if self.startedAt and self.endedAt and self.endedAt < self.startedAt:
            raise ValueError("Sleep end must follow its start.")
        return self


class Activity(Model):
    status: Status
    steps: NonNegative | None = None
    distanceMeters: NonNegative | None = None
    activeEnergyKcal: NonNegative | None = None
    exerciseMinutes: NonNegative | None = None
    standHours: NonNegative | None = None
    activeEnergyGoalKcal: NonNegative | None = None
    exerciseGoalMinutes: NonNegative | None = None
    standGoalHours: NonNegative | None = None
    moveMode: Literal["energy", "time", "unknown"]
    moveMinutes: NonNegative | None = None
    moveGoalMinutes: NonNegative | None = None


class HeartRate(Model):
    status: Status
    bpm: Annotated[float, Field(gt=0, allow_inf_nan=False)] | None = None
    measuredAt: AwareDatetime | None = None

    @model_validator(mode="after")
    def check_sample_time(self) -> Self:
        if self.bpm is not None and self.measuredAt is None:
            raise ValueError("Heart-rate values require a measurement timestamp.")
        return self


class Workout(Model):
    status: Status
    kind: ShortText | None = None
    startedAt: AwareDatetime | None = None
    endedAt: AwareDatetime | None = None
    durationSeconds: NonNegative | None = None
    distanceMeters: NonNegative | None = None
    activeEnergyKcal: NonNegative | None = None

    @model_validator(mode="after")
    def check_interval(self) -> Self:
        if self.startedAt and self.endedAt and self.endedAt < self.startedAt:
            raise ValueError("Workout end must follow its start.")
        return self


class Snapshot(Model):
    schemaVersion: Literal[1]
    dataMode: Literal["healthkit", "demo"]
    generatedAt: AwareDatetime
    timeZone: Annotated[str, Field(min_length=1, max_length=80)]
    day: date
    sourcePolicy: Literal["healthKit"]
    sleep: Sleep
    activity: Activity
    heartRate: HeartRate
    workout: Workout
    warnings: Annotated[list[Annotated[str, Field(max_length=300)]], Field(max_length=24)]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def require_integer_version(cls, value: object) -> object:
        if type(value) is not int:
            raise ValueError("schemaVersion must be an integer.")
        return value

    @field_validator("day", mode="before")
    @classmethod
    def require_iso_day(cls, value: object) -> object:
        if type(value) is date:
            return value
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError("day must use YYYY-MM-DD.")
        return date.fromisoformat(value)

    @field_validator("timeZone")
    @classmethod
    def require_zone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("timeZone must be an IANA timezone.") from None
        return value

    @model_validator(mode="after")
    def check_local_day(self) -> Self:
        if self.generatedAt.astimezone(ZoneInfo(self.timeZone)).date() != self.day:
            raise ValueError("day must match generatedAt in timeZone.")
        return self
