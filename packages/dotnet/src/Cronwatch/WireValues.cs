using System;

namespace Cronwatch;

/// <summary>
/// A run's status as stored: <c>running</c>, <c>ok</c>, <c>failed</c>, or <c>timeout</c>. Stored
/// values come from other writers, so any other string passes through unharmed.
/// </summary>
/// <param name="Value">The stored string.</param>
public readonly record struct RunStatus(string Value)
{
    /// <summary>A run still going.</summary>
    public static RunStatus Running { get; } = new("running");

    /// <summary>A run that succeeded.</summary>
    public static RunStatus Ok { get; } = new("ok");

    /// <summary>A run that failed.</summary>
    public static RunStatus Failed { get; } = new("failed");

    /// <summary>A run a check marked stuck.</summary>
    public static RunStatus Timeout { get; } = new("timeout");

    /// <summary>The status named by a stored string.</summary>
    public static implicit operator RunStatus(string value) => new(value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>The stored string.</summary>
    public override string ToString() => Value ?? "";
}

/// <summary>
/// A condition an alert opens: <c>missed</c>, <c>failed</c>, <c>stuck</c>, <c>slow</c>,
/// <c>over_budget</c>, or <c>under_floor</c>.
/// </summary>
/// <param name="Value">The stored string.</param>
public readonly record struct Condition(string Value)
{
    /// <summary>A run that did not start in time.</summary>
    public static Condition Missed { get; } = new("missed");

    /// <summary>Failed runs, as many in a row as the job allows.</summary>
    public static Condition Failed { get; } = new("failed");

    /// <summary>A run still going past its timeout.</summary>
    public static Condition Stuck { get; } = new("stuck");

    /// <summary>A run that took too long.</summary>
    public static Condition Slow { get; } = new("slow");

    /// <summary>A metric over its budget.</summary>
    public static Condition OverBudget { get; } = new("over_budget");

    /// <summary>A metric under its floor.</summary>
    public static Condition UnderFloor { get; } = new("under_floor");

    /// <summary>Every condition, in the SDK's order.</summary>
    public static System.Collections.Generic.IReadOnlyList<Condition> All { get; } = [Missed, Failed, Stuck, Slow, OverBudget, UnderFloor];

    /// <summary>The condition named by a stored string.</summary>
    public static implicit operator Condition(string value) => new(value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>The stored string.</summary>
    public override string ToString() => Value ?? "";
}

/// <summary>An alert's type: a <see cref="Condition"/>'s name, or <c>recovered</c>.</summary>
/// <param name="Value">The stored string.</param>
public readonly record struct AlertType(string Value)
{
    /// <summary>A run did not start in time.</summary>
    public static AlertType Missed { get; } = new("missed");

    /// <summary>A run failed.</summary>
    public static AlertType Failed { get; } = new("failed");

    /// <summary>A run is stuck.</summary>
    public static AlertType Stuck { get; } = new("stuck");

    /// <summary>A run was slow.</summary>
    public static AlertType Slow { get; } = new("slow");

    /// <summary>A metric went over its budget.</summary>
    public static AlertType OverBudget { get; } = new("over_budget");

    /// <summary>A metric fell under its floor.</summary>
    public static AlertType UnderFloor { get; } = new("under_floor");

    /// <summary>Conditions that alerted have closed.</summary>
    public static AlertType Recovered { get; } = new("recovered");

    /// <summary>The type named by a stored string.</summary>
    public static implicit operator AlertType(string value) => new(value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>The type of an alert that opens this condition.</summary>
    public static AlertType Of(Condition condition) => new(condition.Value);

    /// <summary>The stored string.</summary>
    public override string ToString() => Value ?? "";
}

/// <summary>
/// A job's health as a summary reports it: <c>healthy</c>, <c>late</c>, <c>failing</c>,
/// <c>stuck</c>, <c>silenced</c>, or <c>never_ran</c>.
/// </summary>
/// <param name="Value">The reported string.</param>
public readonly record struct JobHealth(string Value)
{
    /// <summary>Nothing is wrong.</summary>
    public static JobHealth Healthy { get; } = new("healthy");

    /// <summary>A run is missed.</summary>
    public static JobHealth Late { get; } = new("late");

    /// <summary>Runs are failing.</summary>
    public static JobHealth Failing { get; } = new("failing");

    /// <summary>A run is stuck.</summary>
    public static JobHealth Stuck { get; } = new("stuck");

    /// <summary>Alerts are silenced.</summary>
    public static JobHealth Silenced { get; } = new("silenced");

    /// <summary>The job has never run.</summary>
    public static JobHealth NeverRan { get; } = new("never_ran");

    /// <summary>The health named by a string.</summary>
    public static implicit operator JobHealth(string value) => new(value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>The reported string.</summary>
    public override string ToString() => Value ?? "";
}
