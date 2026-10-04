//! zpui reactive core: App, entities, contexts, executors, actions and keymaps.
//! See docs/core-model.md for the design.

pub const type_id = @import("type_id.zig");
pub const subscriber_set = @import("subscriber_set.zig");
pub const executor = @import("executor.zig");
pub const entity = @import("entity.zig");
pub const app = @import("app.zig");
pub const context = @import("context.zig");
pub const action = @import("action.zig");
pub const key_context = @import("key_context.zig");
pub const keymap = @import("keymap.zig");
pub const dispatch_tree = @import("dispatch_tree.zig");
pub const test_platform = @import("test_platform.zig");
pub const lifecycle = @import("lifecycle.zig");

pub const TypeId = type_id.TypeId;
pub const typeId = type_id.typeId;
pub const Subscription = subscriber_set.Subscription;
pub const Subscriptions = subscriber_set.Subscriptions;
pub const Task = executor.Task;
pub const CancelToken = executor.CancelToken;
pub const ForegroundExecutor = executor.ForegroundExecutor;
pub const BackgroundExecutor = executor.BackgroundExecutor;
pub const EntityId = entity.EntityId;
pub const Entity = entity.Entity;
pub const WeakEntity = entity.WeakEntity;
pub const AnyEntity = entity.AnyEntity;
pub const AnyWeakEntity = entity.AnyWeakEntity;
pub const App = app.App;
pub const Context = context.Context;
pub const Listener = context.Listener;
pub const Action = action;
pub const AnyAction = action.AnyAction;
pub const ActionRegistry = action.ActionRegistry;
pub const NoAction = action.NoAction;
pub const Unbind = action.Unbind;
pub const KeyContext = key_context.KeyContext;
pub const KeyBindingContextPredicate = key_context.Predicate;
pub const Keystroke = keymap.Keystroke;
pub const KeyBinding = keymap.KeyBinding;
pub const BindingSpec = keymap.BindingSpec;
pub const Keymap = keymap.Keymap;
pub const parseKeystroke = keymap.parseKeystroke;
pub const DispatchTree = dispatch_tree.DispatchTree;
pub const DispatchPhase = dispatch_tree.DispatchPhase;
pub const FocusId = dispatch_tree.FocusId;
pub const PendingInput = dispatch_tree.PendingInput;
pub const TestPlatform = test_platform.TestPlatform;
pub const TestDispatcher = test_platform.TestDispatcher;

test {
    _ = type_id;
    _ = subscriber_set;
    _ = executor;
    _ = entity;
    _ = app;
    _ = context;
    _ = action;
    _ = key_context;
    _ = keymap;
    _ = dispatch_tree;
    _ = test_platform;
    _ = @import("app_tests.zig");
    _ = @import("lifecycle_tests.zig");
}
