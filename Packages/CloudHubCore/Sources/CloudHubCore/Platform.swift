import Foundation

/*
 * The view models are ObservableObjects so the app runs on iOS 15, which has
 * no Observation framework. Combine provides ObservableObject and @Published
 * on Apple platforms; Linux has no Combine, so the package's tests there get
 * inert stand-ins -- nothing on Linux observes the models, they only need to
 * compile and hold their values.
 */
#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
