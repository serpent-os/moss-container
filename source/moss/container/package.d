/*
 * This file is part of moss-container.
 *
 * Copyright © 2020-2022 Serpent OS Developers
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 */

module moss.container;
import std.stdio : stderr, stdin, stdout;
import std.exception : enforce;
import std.process;
import std.file : exists, remove, symlink;
import std.string : empty, toStringz, format;
import core.sys.linux.sched;
import std.path : buildPath;

public import moss.container.device;
public import moss.container.mounts;
public import moss.container.process;

import moss.container.context;

/**
 * A Container is used for the purpose of isolating newly launched processes.
 */
public final class Container
{
    /**
     * Create a new container
     */
    this()
    {
        /* Default mount points */
        mountPoints = [
            MountPoint("proc", "proc",
                    MountOptions.NoSuid | MountOptions.NoDev | MountOptions.NoExec | MountOptions.RelativeAccessTime,
                    "/proc"),
            MountPoint("sysfs", "sysfs",
                    MountOptions.NoSuid | MountOptions.NoDev | MountOptions.NoExec | MountOptions.RelativeAccessTime,
                    "/sys"),
            MountPoint("tmpfs", "tmpfs", MountOptions.NoSuid | MountOptions.NoDev, "/tmp"),

            /* /dev points */
            MountPoint("tmpfs", "tmpfs", MountOptions.NoSuid | MountOptions.NoDev, "/dev/shm"),
            MountPoint("devpts", "devpts",
                    MountOptions.NoSuid | MountOptions.NoExec | MountOptions.RelativeAccessTime,
                    "/dev/pts"),
        ];
    }

    /**
     * Add a process to this container
     */
    void add(Process p) @safe
    {
        processes ~= p;
    }

    /**
     * Add a mountpoint to the system
     */
    void add(MountPoint p) @safe
    {
        mountPoints ~= p;
    }

    /**
     * Return the working directory used for the process
     */
    pure @property const(string) workDir() @safe @nogc nothrow const
    {
        return cast(const(string)) workDir;
    }

    /**
     * Set the working directory in which to execute the process
     */
    pure @property void workDir(in string newDir) @safe @nogc nothrow
    {
        _workDir = newDir;
    }

    /** 
     * Return the chroot directory we intend to use
     */
    pure @property const(string) chrootDir() @safe @nogc nothrow const
    {
        return cast(const(string)) _chrootDir;
    }

    /**
     * Update the chroot directory
     */
    pure @property void chrootDir(in string d) @safe @nogc nothrow
    {
        _chrootDir = d;
    }

    /**
     * Access the environment property
     */
    pragma(inline, true) pure @property inout(string[string]) environment() @safe @nogc nothrow inout
    {
        return _environ;
    }

    /**
     * Returns whether networking is enabled
     */
    pure @property bool networking() @safe @nogc nothrow const
    {
        return _networking;
    }

    /**
     * Enable or disable networking
     */
    pure @property void networking(bool b) @safe @nogc nothrow
    {
        _networking = b;
    }

    /**
     * Run the associated args (cmdline) with various settings in place
     */
    int run() @system
    {
        enforce(!_chrootDir.empty, "Cannot run without a valid chroot directory");

        detachNamespace();

        /* Setup mounts */
        foreach (m; mountPoints)
        {
            m.up();
        }

        configureDevfs();

        /* Inspect now the environment is ready */
        context.inspectRoot();

        foreach (p; processes)
        {
            p.run(chrootDir, environment);
        }

        for (auto i = mountPoints.length; i > 0; i--)
        {
            auto m = &mountPoints[i - 1];
            m.down();
        }

        return 0;
    }

private:

    void detachNamespace()
    {
        auto flags = CLONE_NEWNS | CLONE_NEWPID;
        if (!networking)
        {
            flags |= CLONE_NEWNET | CLONE_NEWUTS;
        }

        auto ret = unshare(flags);
        enforce(ret == 0, "derpy mcderpderp");
    }

    /**
     * Configure the /dev tree to be valid
     */
    void configureDevfs()
    {

        auto symlinkSources = [
            "/proc/self/fd", "/proc/self/fd/0", "/proc/self/fd/1",
            "/proc/self/fd/2", "pts/ptmx"
        ];

        auto symlinkTargets = [
            "/dev/fd", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/ptmx"
        ];

        static DeviceNode[] nodes = [
            DeviceNode("/dev/null", S_IFCHR | octal!666, mkdev(1, 3)),
            DeviceNode("/dev/zero", S_IFCHR | octal!666, mkdev(1, 5)),
            DeviceNode("/dev/full", S_IFCHR | octal!666, mkdev(1, 7)),
            DeviceNode("/dev/random", S_IFCHR | octal!666, mkdev(1, 8)),
            DeviceNode("/dev/urandom", S_IFCHR | octal!666, mkdev(1, 9)),
            DeviceNode("/dev/tty", S_IFCHR | octal!666, mkdev(5, 0)),
        ];

        /* Link sources to targets */
        foreach (i; 0 .. symlinkSources.length)
        {
            auto source = symlinkSources[i];
            auto target = context.joinPath(symlinkTargets[i]);

            /* Remove old target */
            if (target.exists)
            {
                target.remove();
            }

            /* Link source to target */
            symlink(source, target);
        }

        /* Create our nodes */
        foreach (ref n; nodes)
        {
            n.create();
        }
    }

    bool _networking = true;
    string _workDir = ".";
    string[string] _environ = null;
    string _chrootDir = null;
    const string user = "nobody";

    Process[] processes;
    MountPoint[] mountPoints;
}
