/*
 * Copyright (c) 2011-2015 Wingpanel Developers (http://launchpad.net/wingpanel)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA.
 */

public class Wingpanel.PanelWindow : Gtk.Window {
    public Services.PopoverManager popover_manager;

    private Widgets.Panel panel;

    uint timeout;

    private int monitor_number;
    private int monitor_width;
    private int monitor_height;
    private int monitor_x;
    private int monitor_y;
    private int panel_height;
    private bool expanded = false;
    private int panel_displacement;
    private uint shrink_timeout = 0;
    private bool hiding = false;
    private bool strut = true;
    private string autohide = Services.PanelSettings.get_default ().autohide;
    private int autohide_delay = Services.PanelSettings.get_default ().delay;
    private Wnck.Screen wnck_screen = Wnck.Screen.get_default ();

    public PanelWindow (Gtk.Application application) {
        Object (
            application: application,
            app_paintable: true,
            decorated: false,
            resizable: false,
            skip_pager_hint: true,
            skip_taskbar_hint: true,
            type_hint: Gdk.WindowTypeHint.DOCK,
            vexpand: false
        );

        monitor_number = screen.get_primary_monitor ();

        var style_context = get_style_context ();
        style_context.add_class (Widgets.StyleClass.PANEL);
        style_context.add_class (Gtk.STYLE_CLASS_MENUBAR);

        this.screen.size_changed.connect (update_panel_dimensions);
        this.screen.monitors_changed.connect (update_panel_dimensions);
        this.screen_changed.connect (update_visual);
        wnck_screen.active_window_changed.connect (active_window_changed);
        this.enter_notify_event.connect (show_panel);
        this.motion_notify_event.connect (show_panel);
        this.leave_notify_event.connect (hide_panel);

        update_visual ();

        popover_manager = new Services.PopoverManager (this);

        panel = new Widgets.Panel (popover_manager);
        panel.realize.connect (on_realize);

        var cycle_action = new SimpleAction ("cycle", null);
        cycle_action.activate.connect (() => panel.cycle (true));

        var cycle_back_action = new SimpleAction ("cycle-back", null);
        cycle_back_action.activate.connect (() => panel.cycle (false));

        application.add_action (cycle_action);
        application.add_action (cycle_back_action);
        application.add_accelerator ("<Control>Tab", "app.cycle", null);
        application.add_accelerator ("<Control><Shift>Tab", "app.cycle-back", null);

        Services.PanelSettings.get_default ().notify["autohide"].connect (() => {
            autohide = Services.PanelSettings.get_default ().autohide;
            update_autohide_mode ();
        });

        Services.PanelSettings.get_default ().notify["delay"].connect (() => {
            autohide_delay = Services.PanelSettings.get_default ().delay;
        });

        add (panel);
    }

    private bool animation_step () {
        if (hiding) {
            if (panel_displacement >= -1 || popover_manager.current_indicator != null) {
                timeout = 0;
                if (strut == true) {
                    update_panel_dimensions ();
                }
                return false;
            }
            panel_displacement++;
        } else {
            if (panel_displacement <= panel_height * (-1)) {
                timeout = 0;
                if (strut == true) {
                    update_panel_dimensions ();
                }
                return false;
            }
            panel_displacement--;
        }

        animate_panel ();

        return true;
    }

    private void on_realize () {
        update_panel_dimensions ();

        Services.BackgroundManager.initialize (this.monitor_number, panel_height);

        update_autohide_mode ();
    }

    private void active_window_changed (Wnck.Window? prev_active_window) {
        unowned Wnck.Window? active_window = wnck_screen.get_active_window();
        if (autohide == "Dodge" || autohide == "Dodge-Float")
            update_visibility_active_change (active_window);

        if (prev_active_window != null)
            prev_active_window.state_changed.disconnect (active_window_state_changed);
        if (active_window != null)
            active_window.state_changed.connect (active_window_state_changed);
    }

    private void active_window_state_changed (Wnck.Window? window,
            Wnck.WindowState changed_mask, Wnck.WindowState new_state) {
        if (autohide == "Dodge" || autohide == "Dodge-Float")
            update_visibility_active_change (window);
    }

    private void update_visibility_active_change (Wnck.Window? active_window) {
        if (should_hide_active_change (active_window)) {
            hide_panel ();
        } else {
            show_panel ();
        }
    }

    private bool should_hide_active_change (Wnck.Window? active_window) {
        unowned Wnck.Workspace active_workspace = wnck_screen.get_active_workspace ();

        return ((active_window != null) && !active_window.is_minimized () && right_type (active_window)
                && active_window.is_visible_on_workspace (active_workspace)
                && (active_window.get_window_type () == Wnck.WindowType.DIALOG) ?
                    would_intersect_shown_panel (active_window) :
                    (in_panel_x_range (active_window) && is_maximized_at_all (active_window)));
    }

    private bool would_intersect_shown_panel (Wnck.Window? window) {
        Gdk.Rectangle shown_panel_rect = Gdk.Rectangle ();
        shown_panel_rect.x = monitor_x;
        shown_panel_rect.y = monitor_y;
        shown_panel_rect.width = monitor_width;
        shown_panel_rect.height = panel_height;

        int xp, yp, widthp, heightp;
        window.get_geometry (out xp, out yp, out widthp, out heightp);

        Gdk.Rectangle window_rect = Gdk.Rectangle ();
        window_rect.x = xp;
        window_rect.width = widthp;
        if (strut && is_maximized_at_all (window)) {
            window_rect.y = yp - panel_height;
            window_rect.height = heightp + panel_height;
        } else {
            window_rect.y = yp;
            window_rect.height = heightp;
        }

        return window_rect.intersect (shown_panel_rect, null);
    }

    private bool in_panel_x_range (Wnck.Window? window) {
        int xp, yp, widthp, heightp;
        window.get_geometry (out xp, out yp, out widthp, out heightp);
        if (xp > monitor_x)
            return (monitor_x + monitor_width > xp);
        else if (xp < monitor_x)
            return (xp + widthp > monitor_x);
        else
            return (xp + widthp > 0 && monitor_x + monitor_width > 0);
    }

    private bool right_type (Wnck.Window? active_window) {
        unowned Wnck.WindowType type = active_window.get_window_type ();
        return (type == Wnck.WindowType.NORMAL || type == Wnck.WindowType.DIALOG
                || type == Wnck.WindowType.TOOLBAR || type == Wnck.WindowType.UTILITY);
    }

    private bool is_maximized_at_all (Wnck.Window window) {
        return (window.is_maximized_horizontally ()
                || window.is_maximized_vertically ());
    }

    private bool hide_panel () {
        if (timeout > 0) {
            Source.remove (timeout);
        }
        if (autohide == "Dodge" || autohide == "Dodge-Float") {
            if (!should_hide_active_change (wnck_screen.get_active_window())) {
                return true;
            }
        }
        if (popover_manager.current_indicator == null) {
            Thread.usleep (autohide_delay * 1000);
        }
        strut = true;
        hiding = true;
        timeout = Timeout.add (100 / panel_height, animation_step);
        return true;
    }

    private bool show_panel () {
        if (timeout > 0) {
            Source.remove (timeout);
        }
        if (popover_manager.current_indicator == null && autohide != "Disabled") {
            Thread.usleep (autohide_delay * 1000);
        }
        if (autohide == "Dodge-Float" || autohide == "Float") {
            strut = false;
        } else {
            strut = true;
        }
        hiding = false;
        if (autohide == "Disabled") {
            timeout = Timeout.add (300 / panel_height, animation_step);
        } else {
            timeout = Timeout.add (100 / panel_height, animation_step);
        }
        return true;
    }

    private void update_autohide_mode () {
        switch (autohide) {
            case "Disabled":
                this.enter_notify_event.disconnect (show_panel);
                this.motion_notify_event.disconnect (show_panel);
                this.leave_notify_event.disconnect (hide_panel);
                show_panel ();
                break;
            case "Dodge":
            case "Dodge-Float":
                this.enter_notify_event.connect (show_panel);
                this.motion_notify_event.connect (show_panel);
                this.leave_notify_event.connect (hide_panel);
                show_panel ();
                break;
            default:
                this.enter_notify_event.connect (show_panel);
                this.motion_notify_event.connect (show_panel);
                this.leave_notify_event.connect (hide_panel);
                hide_panel ();
                break;
        }
    }

    private void update_panel_dimensions () {
        panel_height = panel.get_allocated_height ();

        monitor_number = screen.get_primary_monitor ();
        Gdk.Rectangle monitor_dimensions;
        this.screen.get_monitor_geometry (monitor_number, out monitor_dimensions);

        monitor_width = monitor_dimensions.width;
        monitor_height = monitor_dimensions.height;

        this.set_size_request (monitor_width, (popover_manager.current_indicator != null ? monitor_height : -1));

        monitor_x = monitor_dimensions.x;
        monitor_y = monitor_dimensions.y;

        this.move (monitor_x, monitor_y - (panel_height + panel_displacement));

        update_struts ();
    }

    private void animate_panel () {
        panel_height = panel.get_allocated_height ();

        monitor_number = screen.get_primary_monitor ();
        Gdk.Rectangle monitor_dimensions;
        this.screen.get_monitor_geometry (monitor_number, out monitor_dimensions);

        monitor_width = monitor_dimensions.width;
        monitor_height = monitor_dimensions.height;

        this.set_size_request (monitor_width, (popover_manager.current_indicator != null ? monitor_height : -1));

        monitor_x = monitor_dimensions.x;
        monitor_y = monitor_dimensions.y;

        this.move (monitor_x, monitor_y - (panel_height + panel_displacement));
    }

    private void update_visual () {
        var visual = this.screen.get_rgba_visual ();

        if (visual == null) {
            warning ("Compositing not available, things will Look Bad (TM)");
        } else {
            this.set_visual (visual);
        }
    }

    private void update_struts () {
        if (!this.get_realized () || panel == null) {
            return;
        }

        var monitor = monitor_number == -1 ? this.screen.get_primary_monitor () : monitor_number;
        var position_top = monitor_y - panel_displacement;
        var scale_factor = this.get_scale_factor ();

        Gdk.Atom atom;
        Gdk.Rectangle primary_monitor_rect;

        long struts[12];

        this.screen.get_monitor_geometry (monitor, out primary_monitor_rect);

		// We need to manually include the scale factor here as GTK gives us unscaled sizes for widgets
        struts = { 0, 0, position_top * scale_factor, 0, /* strut-left, strut-right, strut-top, strut-bottom */
                   0, 0, /* strut-left-start-y, strut-left-end-y */
                   0, 0, /* strut-right-start-y, strut-right-end-y */
                   monitor_x, ((monitor_x + monitor_width) * scale_factor) - 1, /* strut-top-start-x, strut-top-end-x */
                   0, 0 }; /* strut-bottom-start-x, strut-bottom-end-x */

        atom = Gdk.Atom.intern ("_NET_WM_STRUT_PARTIAL", false);

        Gdk.property_change (this.get_window (), atom, Gdk.Atom.intern ("CARDINAL", false),
                             32, Gdk.PropMode.REPLACE, (uint8[])struts, 12);
    }

    public void set_expanded (bool expand) {
        if (expand && !this.expanded) {
            Services.BackgroundManager.get_default ().remember_window ();

            this.expanded = true;

            if (shrink_timeout > 0) {
                Source.remove (shrink_timeout);
                shrink_timeout = 0;
            }

            this.set_size_request (monitor_width, monitor_height);
        } else if (!expand) {
            Services.BackgroundManager.get_default ().restore_window ();

            this.expanded = false;

            if (shrink_timeout > 0) {
                Source.remove (shrink_timeout);
            }

            shrink_timeout = Timeout.add (300, () => {
                shrink_timeout = 0;
                this.set_size_request (monitor_width, expanded ? monitor_height : -1);
                this.resize (monitor_width, expanded ? monitor_height : 1);
                return false;
            });
        }
    }
}
