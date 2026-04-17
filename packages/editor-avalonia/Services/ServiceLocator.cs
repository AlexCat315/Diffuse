using System;
using System.Collections.Generic;

namespace Guava.Editor.Services;

/// <summary>
/// Minimal static service locator. Sufficient for the current editor's DI needs —
/// every panel VM reaches into a tiny number of singletons (RPC client, stores,
/// engine process). No framework required.
///
/// Not a long-term ambition; a heavier container can be swapped in later without
/// touching call sites if they all go through <see cref="Get{T}"/>.
/// </summary>
public static class ServiceLocator
{
    private static readonly Dictionary<Type, object> _services = new();

    public static void Register<T>(T instance) where T : class
    {
        _services[typeof(T)] = instance;
    }

    public static T Get<T>() where T : class
    {
        if (_services.TryGetValue(typeof(T), out var svc)) return (T)svc;
        throw new InvalidOperationException($"Service not registered: {typeof(T).Name}");
    }

    public static T? TryGet<T>() where T : class
    {
        return _services.TryGetValue(typeof(T), out var svc) ? (T)svc : null;
    }

    public static void Clear() => _services.Clear();
}
